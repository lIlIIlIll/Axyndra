package agent_tui

import core.*
import markdown.*
import std.collection.*
import std.deriving.*

@Derive[Equatable]
enum PlanReviewEffect {
    Close
    | CopyText(String)
    | ReviewPlan(String, TuiPlanReviewDecision, String)
}

class PlanReviewTransition {
    let update: UpdateResult
    let effect: ?PlanReviewEffect

    init(update: UpdateResult, effect!: ?PlanReviewEffect = None) {
        this.update = update
        this.effect = effect
    }
}

class PlanReviewProbeSnapshot {
    let contentHash: String
    let selected: Int64
    let focus: PlanReviewFocus
    let tocSelected: Int64
    let mode: String
    let body: String
    let scroll: Int64
    let annotationCount: Int64
    let editorValue: String
    let decisionPending: Bool
    let updatePending: Bool
    let documentArea: Rect
    let actionsArea: Rect
    let layoutCount: Int64
    let cacheEntries: Int64
    let parseCount: Int64

    init(
        contentHash: String,
        selected: Int64,
        focus: PlanReviewFocus,
        tocSelected: Int64,
        mode: String,
        body: String,
        scroll: Int64,
        annotationCount: Int64,
        editorValue: String,
        decisionPending: Bool,
        updatePending: Bool,
        documentArea: Rect,
        actionsArea: Rect,
        layoutCount: Int64,
        cacheEntries: Int64,
        parseCount: Int64
    ) {
        this.contentHash = contentHash
        this.selected = selected
        this.focus = focus
        this.tocSelected = tocSelected
        this.mode = mode
        this.body = body
        this.scroll = scroll
        this.annotationCount = annotationCount
        this.editorValue = editorValue
        this.decisionPending = decisionPending
        this.updatePending = updatePending
        this.documentArea = documentArea
        this.actionsArea = actionsArea
        this.layoutCount = layoutCount
        this.cacheEntries = cacheEntries
        this.parseCount = parseCount
    }
}

// Opaque outside PlanReviewController: tests only hold and return this value.
class PlanReviewProbeState {
    private let applyState: (PlanReviewController) -> Unit

    init(applyState: (PlanReviewController) -> Unit) {
        this.applyState = applyState
    }

    func restoreInto(controller: PlanReviewController): Unit {
        applyState(controller)
    }
}

class PlanReviewController {
    private var planReviewHash = ""
    private var planReviewSelected: Int64 = 0
    private var planReviewFocus = PlanReviewFocus.Actions
    private var planReviewTocSelected: Int64 = 0
    private var planReviewMode = ""
    private var planReviewAnnotationSection = ""
    private var planReviewAnnotationLine = ""
    private let planReviewAnnotations = ArrayList<PlanReviewAnnotation>()
    private var planReviewDocumentCacheKey = ""
    private var planReviewDocumentCache = Document([])
    private var planReviewSectionsCache: Array<PlanReviewSection> = []
    private var planReviewPreviewCacheKey = ""
    private var planReviewPreviewCache = MarkdownPreviewIndex([])
    private var planReviewWindowCache = DocumentWindowCache()
    private var planReviewParseCount: Int64 = 0
    private var planReviewVisibleRows: Int64 = 0
    private var planReviewBodyArea = Rect(0, 0, 0, 0)
    private var planReviewTocArea = Rect(0, 0, 0, 0)
    private var planReviewTocStart: Int64 = 0
    private var planReviewDocumentArea = Rect(0, 0, 0, 0)
    private var planReviewActionsArea = Rect(0, 0, 0, 0)
    private var planReviewEditorArea = Rect(0, 0, 0, 0)
    private var planReviewDecisionPending = false
    private var planReviewUpdatePending = false
    private let planReviewEditor = TextArea(
        block: Some(Block(title: "Plan Review")),
        lineNumbers: false,
        markdownEditing: true
    )
    private var documentBody = ""
    private var documentScroll: Int64 = 0
    private var documentRevision: Int64 = 0
    private var activeModalArea = Rect(0, 0, 0, 0)
    private var status = "ready"
    private var themeName = ""
    private var customThemeDefinitions: Array<TuiThemeDefinition> = []

    func isActive(): Bool {
        planReviewHash != ""
    }

    func hasPending(): Bool {
        planReviewDecisionPending || planReviewUpdatePending
    }

    func statusText(): String {
        status
    }

    func beginProbe(): PlanReviewProbeState {
        let savedHash = planReviewHash
        let savedSelected = planReviewSelected
        let savedFocus = planReviewFocus
        let savedTocSelected = planReviewTocSelected
        let savedMode = planReviewMode
        let savedAnnotationSection = planReviewAnnotationSection
        let savedAnnotationLine = planReviewAnnotationLine
        let savedAnnotations = planReviewAnnotations.toArray()
        let savedDocumentCacheKey = planReviewDocumentCacheKey
        let savedDocumentCache = planReviewDocumentCache
        let savedSectionsCache = planReviewSectionsCache
        let savedPreviewCacheKey = planReviewPreviewCacheKey
        let savedPreviewCache = planReviewPreviewCache
        let savedWindowCache = planReviewWindowCache
        let savedParseCount = planReviewParseCount
        let savedVisibleRows = planReviewVisibleRows
        let savedBodyArea = planReviewBodyArea
        let savedTocArea = planReviewTocArea
        let savedTocStart = planReviewTocStart
        let savedDocumentArea = planReviewDocumentArea
        let savedActionsArea = planReviewActionsArea
        let savedEditorArea = planReviewEditorArea
        let savedDecisionPending = planReviewDecisionPending
        let savedUpdatePending = planReviewUpdatePending
        let savedEditorValue = planReviewEditor.value
        let savedBody = documentBody
        let savedScroll = documentScroll
        let savedRevision = documentRevision
        let savedActiveModalArea = activeModalArea
        let savedStatus = status
        let state = PlanReviewProbeState({controller =>
            controller.planReviewHash = savedHash
            controller.planReviewSelected = savedSelected
            controller.planReviewFocus = savedFocus
            controller.planReviewTocSelected = savedTocSelected
            controller.planReviewMode = savedMode
            controller.planReviewAnnotationSection = savedAnnotationSection
            controller.planReviewAnnotationLine = savedAnnotationLine
            controller.planReviewAnnotations.clear()
            for (annotation in savedAnnotations) {
                controller.planReviewAnnotations.add(annotation)
            }
            controller.planReviewDocumentCacheKey = savedDocumentCacheKey
            controller.planReviewDocumentCache = savedDocumentCache
            controller.planReviewSectionsCache = savedSectionsCache
            controller.planReviewPreviewCacheKey = savedPreviewCacheKey
            controller.planReviewPreviewCache = savedPreviewCache
            controller.planReviewWindowCache = savedWindowCache
            controller.planReviewParseCount = savedParseCount
            controller.planReviewVisibleRows = savedVisibleRows
            controller.planReviewBodyArea = savedBodyArea
            controller.planReviewTocArea = savedTocArea
            controller.planReviewTocStart = savedTocStart
            controller.planReviewDocumentArea = savedDocumentArea
            controller.planReviewActionsArea = savedActionsArea
            controller.planReviewEditorArea = savedEditorArea
            controller.planReviewDecisionPending = savedDecisionPending
            controller.planReviewUpdatePending = savedUpdatePending
            controller.planReviewEditor.setValue(savedEditorValue)
            controller.documentBody = savedBody
            controller.documentScroll = savedScroll
            controller.documentRevision = savedRevision
            controller.activeModalArea = savedActiveModalArea
            controller.status = savedStatus
        })
        // Keep probe layout/cache counters isolated from the live review.
        planReviewWindowCache = DocumentWindowCache()
        state
    }

    func restoreProbe(state: PlanReviewProbeState): Unit {
        state.restoreInto(this)
    }

    func probeSnapshot(): PlanReviewProbeSnapshot {
        PlanReviewProbeSnapshot(
            planReviewHash,
            planReviewSelected,
            planReviewFocus,
            planReviewTocSelected,
            planReviewMode,
            documentBody,
            documentScroll,
            planReviewAnnotations.size,
            planReviewEditor.value,
            planReviewDecisionPending,
            planReviewUpdatePending,
            planReviewDocumentArea,
            planReviewActionsArea,
            planReviewWindowCache.layouts(),
            planReviewWindowCache.entries(),
            planReviewParseCount
        )
    }

    func probeSetNavigation(selected: Int64, focus: PlanReviewFocus, tocSelected: Int64, scroll: Int64): Unit {
        planReviewSelected = selected
        planReviewFocus = focus
        planReviewTocSelected = tocSelected
        documentScroll = scroll
    }

    func probeAddAnnotation(section: String, line: String, note: String): Unit {
        planReviewAnnotations.add(PlanReviewAnnotation(section, line, note))
    }

    func probeSetEditor(mode: String, value: String): Unit {
        planReviewMode = mode
        planReviewEditor.setValue(value)
    }

    func probeSetPending(decision: Bool, update: Bool): Unit {
        planReviewDecisionPending = decision
        planReviewUpdatePending = update
    }

    func setStatusText(value: String): UpdateResult {
        status = value
        dirtyPlanReview()
    }

    func setTheme(name: String, definitions: Array<TuiThemeDefinition>): Unit {
        themeName = name
        customThemeDefinitions = definitions
        documentRevision++
        planReviewDocumentCacheKey = ""
        planReviewPreviewCacheKey = ""
    }

    func open(body: String, preserveReviewState!: Bool = false): UpdateResult {
        let preserveState = preserveReviewState && isActive()
        documentBody = body
        documentRevision++
        planReviewHash = planContentHash(body)
        planReviewMode = ""
        if (!preserveState) {
            documentScroll = 0
            planReviewSelected = 0
            planReviewFocus = PlanReviewFocus.Actions
            planReviewTocSelected = 0
            planReviewAnnotations.clear()
        }
        planReviewDecisionPending = false
        planReviewUpdatePending = false
        status = planReviewFocusStatus(planReviewFocus)
        UpdateResult.next()
    }

    func close(keepStatus!: Bool = false): Unit {
        planReviewHash = ""
        documentBody = ""
        documentScroll = 0
        planReviewSelected = 0
        planReviewFocus = PlanReviewFocus.Actions
        planReviewTocSelected = 0
        planReviewMode = ""
        planReviewAnnotationSection = ""
        planReviewAnnotationLine = ""
        planReviewAnnotations.clear()
        planReviewDecisionPending = false
        planReviewUpdatePending = false
        planReviewBodyArea = Rect(0, 0, 0, 0)
        planReviewTocArea = Rect(0, 0, 0, 0)
        planReviewTocStart = 0
        planReviewDocumentArea = Rect(0, 0, 0, 0)
        planReviewActionsArea = Rect(0, 0, 0, 0)
        planReviewEditorArea = Rect(0, 0, 0, 0)
        activeModalArea = Rect(0, 0, 0, 0)
        if (!keepStatus) {
            status = "ready"
        }
    }

    func paste(text: String): UpdateResult {
        if (hasPending()) {
            return UpdateResult.unchanged()
        }
        if (planReviewMode == "edit" || planReviewMode == "annotate") {
            _ = planReviewEditor.paste(text)
            return dirtyPlanReview()
        }
        UpdateResult.unchanged()
    }

    func updateKey(key: KeyEvent, working: Bool): PlanReviewTransition {
        if (hasPending()) {
            status = if (planReviewUpdatePending) { "updating plan" } else { "reviewing plan" }
            return PlanReviewTransition(UpdateResult.unchanged())
        }
        if (planReviewMode != "") {
            return updatePlanReviewEditor(key, working)
        }
        ensurePlanReviewDocument()
        match (key.code) {
            case KeyCode.Esc =>
                return PlanReviewTransition(
                    UpdateResult.next(),
                    effect: Some(PlanReviewEffect.Close)
                )
            case KeyCode.Char(r'c') => if (!key.modifiers.ctrl && !key.modifiers.alt) {
                return PlanReviewTransition(
                    dirtyPlanReview(),
                    effect: Some(PlanReviewEffect.CopyText(stripPlanReviewLabel(documentBody)))
                )
            }
            case KeyCode.Char(r'e') => if (!key.modifiers.ctrl && !key.modifiers.alt) {
                planReviewMode = "edit"
                planReviewEditor.setValue(stripPlanReviewLabel(documentBody))
                status = "edit plan · Ctrl+S save · Esc return"
                return PlanReviewTransition(dirtyPlanReview())
            }
            case KeyCode.Char(r'u') => if (!key.modifiers.ctrl && !key.modifiers.alt) {
                if (planReviewAnnotations.isEmpty()) {
                    return PlanReviewTransition(UpdateResult.unchanged())
                }
                planReviewAnnotations.remove(at: planReviewAnnotations.size - 1)
                status = "last refinement annotation removed"
                return PlanReviewTransition(dirtyPlanReview())
            }
            case KeyCode.Tab | KeyCode.BackTab =>
                let reverse = key.modifiers.shift || match (key.code) {
                    case KeyCode.BackTab => true
                    case _ => false
                }
                planReviewFocus = if (reverse) {
                    match (planReviewFocus) {
                        case PlanReviewFocus.Actions => if (planReviewTocVisible()) {
                            syncPlanReviewTocToScroll()
                            PlanReviewFocus.Toc
                        } else {
                            PlanReviewFocus.Body
                        }
                        case PlanReviewFocus.Body => PlanReviewFocus.Actions
                        case PlanReviewFocus.Toc => PlanReviewFocus.Body
                    }
                } else {
                    match (planReviewFocus) {
                        case PlanReviewFocus.Actions => PlanReviewFocus.Body
                        case PlanReviewFocus.Body => if (planReviewTocVisible()) {
                            syncPlanReviewTocToScroll()
                            PlanReviewFocus.Toc
                        } else {
                            PlanReviewFocus.Actions
                        }
                        case PlanReviewFocus.Toc => PlanReviewFocus.Actions
                    }
                }
                status = planReviewFocusStatus(planReviewFocus)
                return PlanReviewTransition(dirtyPlanReview())
            case _ => ()
        }
        match (planReviewFocus) {
            case PlanReviewFocus.Actions => updatePlanReviewActions(key, working)
            case PlanReviewFocus.Body => updatePlanReviewBody(key)
            case PlanReviewFocus.Toc => updatePlanReviewToc(key)
        }
    }

    private func updatePlanReviewActions(key: KeyEvent, working: Bool): PlanReviewTransition {
        var changed = false
        match (key.code) {
            case KeyCode.Up | KeyCode.Char(r'k') =>
                let previous = planReviewSelected
                planReviewSelected = max(0, planReviewSelected - 1)
                changed = planReviewSelected != previous
            case KeyCode.Down | KeyCode.Char(r'j') =>
                let previous = planReviewSelected
                planReviewSelected = min(3, planReviewSelected + 1)
                changed = planReviewSelected != previous
            case KeyCode.PageUp => changed = scrollPlanReviewBy(-max(1, planReviewVisibleRows))
            case KeyCode.PageDown => changed = scrollPlanReviewBy(max(1, planReviewVisibleRows))
            case KeyCode.Enter =>
                if (planReviewSelected == 3 && planReviewAnnotations.isEmpty()) {
                    beginPlanReviewAnnotation("Plan", "")
                    status = "refinement feedback · Ctrl+S save · Esc return"
                    return PlanReviewTransition(dirtyPlanReview())
                }
                return resolvePlanReview(working)
            case _ => return PlanReviewTransition(UpdateResult.unchanged())
        }
        PlanReviewTransition(if (changed) { dirtyPlanReview() } else { UpdateResult.unchanged() })
    }

    private func updatePlanReviewBody(key: KeyEvent): PlanReviewTransition {
        var changed = false
        match (key.code) {
            case KeyCode.Up | KeyCode.Char(r'k') => changed = scrollPlanReviewBy(-1)
            case KeyCode.Down | KeyCode.Char(r'j') => changed = scrollPlanReviewBy(1)
            case KeyCode.PageUp => changed = scrollPlanReviewBy(-max(1, planReviewVisibleRows))
            case KeyCode.PageDown => changed = scrollPlanReviewBy(max(1, planReviewVisibleRows))
            case KeyCode.Home | KeyCode.Char(r'g') =>
                changed = documentScroll != 0
                documentScroll = 0
            case KeyCode.End | KeyCode.Char(r'G') =>
                let target = maximumPlanReviewScroll()
                changed = documentScroll != target
                documentScroll = target
            case KeyCode.Left | KeyCode.Char(r'h') =>
                if (planReviewTocVisible()) {
                    planReviewFocus = PlanReviewFocus.Toc
                    syncPlanReviewTocToScroll()
                    status = planReviewFocusStatus(planReviewFocus)
                    changed = true
                }
            case KeyCode.Right | KeyCode.Char(r'l') =>
                planReviewFocus = PlanReviewFocus.Actions
                status = planReviewFocusStatus(planReviewFocus)
                changed = true
            case KeyCode.Char(r'a') =>
                beginPlanReviewAnnotation(
                    currentPlanReviewSection(),
                    currentPlanReviewLineContext()
                )
                changed = true
            case _ => return PlanReviewTransition(UpdateResult.unchanged())
        }
        PlanReviewTransition(if (changed) { dirtyPlanReview() } else { UpdateResult.unchanged() })
    }

    private func updatePlanReviewToc(key: KeyEvent): PlanReviewTransition {
        ensurePlanReviewDocument()
        let sections = planReviewSectionsCache
        if (sections.isEmpty() || !planReviewTocVisible()) {
            planReviewFocus = PlanReviewFocus.Body
            status = planReviewFocusStatus(planReviewFocus)
            return PlanReviewTransition(dirtyPlanReview())
        }
        var changed = false
        match (key.code) {
            case KeyCode.Up | KeyCode.Char(r'k') =>
                let previous = planReviewTocSelected
                planReviewTocSelected = max(0, planReviewTocSelected - 1)
                changed = planReviewTocSelected != previous
            case KeyCode.Down | KeyCode.Char(r'j') =>
                let previous = planReviewTocSelected
                planReviewTocSelected = min(sections.size - 1, planReviewTocSelected + 1)
                changed = planReviewTocSelected != previous
            case KeyCode.Enter | KeyCode.Right | KeyCode.Char(r'l') =>
                documentScroll = min(maximumPlanReviewScroll(), sections[planReviewTocSelected].renderedLine)
                planReviewFocus = PlanReviewFocus.Body
                status = planReviewFocusStatus(planReviewFocus)
                changed = true
            case KeyCode.Char(r'a') =>
                beginPlanReviewAnnotation(sections[planReviewTocSelected].title, "")
                changed = true
            case KeyCode.Char(r'd') =>
                planReviewAnnotations.add(
                    PlanReviewAnnotation(
                        sections[planReviewTocSelected].title,
                        "",
                        "Remove this section.",
                        removeSection: true
                    )
                )
                status = "section marked for removal · u undo"
                changed = true
            case _ => return PlanReviewTransition(UpdateResult.unchanged())
        }
        PlanReviewTransition(if (changed) { dirtyPlanReview() } else { UpdateResult.unchanged() })
    }

    private func beginPlanReviewAnnotation(section: String, line: String): Unit {
        planReviewAnnotationSection = if (section == "") { "Plan" } else { section }
        planReviewAnnotationLine = line
        planReviewMode = "annotate"
        planReviewEditor.setValue("")
        status = "annotate " + planReviewAnnotationSection + " · Ctrl+S save · Esc return"
    }

    private func updatePlanReviewEditor(key: KeyEvent, working: Bool): PlanReviewTransition {
        if (working) {
            status = if (planReviewMode == "edit") { "updating plan" } else { "working" }
            return PlanReviewTransition(UpdateResult.unchanged())
        }
        match (key.code) {
            case KeyCode.Esc =>
                planReviewMode = ""
                status = planReviewFocusStatus(planReviewFocus)
                return PlanReviewTransition(dirtyPlanReview())
            case KeyCode.Char(r's') =>
                if (key.modifiers.ctrl) {
                    let value = planReviewEditor.value.trimAscii()
                    if (value == "") {
                        status = if (planReviewMode == "edit") {
                            "plan must not be empty"
                        } else {
                            "annotation must not be empty"
                        }
                        return PlanReviewTransition(dirtyPlanReview())
                    }
                    if (planReviewMode == "annotate") {
                        planReviewAnnotations.add(
                            PlanReviewAnnotation(
                                planReviewAnnotationSection,
                                planReviewAnnotationLine,
                                value
                            )
                        )
                        planReviewMode = ""
                        status = "refinement annotation saved"
                        return PlanReviewTransition(dirtyPlanReview())
                    }
                    planReviewUpdatePending = true
                    status = "updating plan"
                    return PlanReviewTransition(
                        dirtyPlanReview(),
                        effect: Some(
                            PlanReviewEffect.ReviewPlan(
                                planReviewHash,
                                TuiPlanReviewDecision.UpdatePlan,
                                value
                            )
                        )
                    )
                }
            case _ => ()
        }
        PlanReviewTransition(
            if (planReviewEditor.handle(key)) { dirtyPlanReview() } else { UpdateResult.unchanged() }
        )
    }

    private func resolvePlanReview(working: Bool): PlanReviewTransition {
        if (working) {
            status = "wait for the active turn before reviewing"
            return PlanReviewTransition(dirtyPlanReview())
        }
        let decision = match (planReviewSelected) {
            case 0 => TuiPlanReviewDecision.ApproveFresh
            case 1 => TuiPlanReviewDecision.ApproveCompact
            case 2 => TuiPlanReviewDecision.ApproveKeep
            case _ => TuiPlanReviewDecision.Refine
        }
        let feedback = planReviewFeedback()
        if (decision == TuiPlanReviewDecision.Refine && feedback == "") {
            beginPlanReviewAnnotation("Plan", "")
            status = "refinement feedback · Ctrl+S save · Esc return"
            return PlanReviewTransition(dirtyPlanReview())
        }
        planReviewDecisionPending = true
        status = "reviewing plan"
        PlanReviewTransition(
            dirtyPlanReview(),
            effect: Some(PlanReviewEffect.ReviewPlan(planReviewHash, decision, feedback))
        )
    }

    func updateMouse(mouse: MouseEvent): UpdateResult {
        if (hasPending()) {
            return UpdateResult.unchanged()
        }
        handlePlanReviewMouse(mouse)
    }

    func render(frame: Frame, theme: ProductTheme, terminalUnicode: Bool): Unit {
        renderPlanReviewOverlay(frame, theme, terminalUnicode)
    }

    func acceptTurnResult(
        resultStatus: String,
        action: TuiTurnAction,
        disposition!: TuiPlanReviewDisposition = TuiPlanReviewDisposition.NotApplicable
    ): ?TuiTurnAction {
        status = resultStatus
        let updating = planReviewUpdatePending
        if (updating) {
            planReviewUpdatePending = false
        }
        if (planReviewDecisionPending) {
            planReviewDecisionPending = false
            match (disposition) {
                case TuiPlanReviewDisposition.Consumed => match (action) {
                    case TuiTurnAction.OpenPlanReview(body) =>
                        _ = open(body)
                        return None
                    case TuiTurnAction.NoAction =>
                        close(keepStatus: true)
                        return None
                    case value =>
                        close(keepStatus: true)
                        return Some(value)
                }
                case TuiPlanReviewDisposition.Retain => match (action) {
                    case TuiTurnAction.OpenPlanReview(body) =>
                        _ = open(body)
                        return None
                    case TuiTurnAction.NoAction => return None
                    case value => return Some(value)
                }
                case TuiPlanReviewDisposition.NotApplicable => match (action) {
                    case TuiTurnAction.NoAction => return None
                    case TuiTurnAction.OpenPlanReview(body) =>
                        _ = open(body)
                        return None
                    case value =>
                        close(keepStatus: true)
                        return Some(value)
                }
            }
        }
        if (updating) {
            match (action) {
                case TuiTurnAction.NoAction => return None
                case TuiTurnAction.OpenPlanReview(body) =>
                    _ = open(body, preserveReviewState: true)
                    return None
                case value => return Some(value)
            }
        }
        match (action) {
            case TuiTurnAction.NoAction => None
            case value => Some(value)
        }
    }

    // Approval consumption precedes approved-plan execution.  Closing at
    // this boundary prevents a long model request (or its eventual failure)
    // from leaving an already-spent review looking retryable.
    func acceptConsumed(contentHash: String): Bool {
        if (!planReviewDecisionPending || planReviewHash != contentHash) {
            return false
        }
        close(keepStatus: true)
        status = "executing approved plan"
        true
    }

    func completeWithoutResult(): UpdateResult {
        if (planReviewDecisionPending) {
            planReviewDecisionPending = false
            status = "plan review returned no result; review state preserved"
        }
        if (planReviewUpdatePending) {
            planReviewUpdatePending = false
            status = "plan update returned no result; edit preserved"
        }
        dirtyPlanReview()
    }

    func failAgentTurn(): UpdateResult {
        if (planReviewDecisionPending) {
            planReviewDecisionPending = false
            status = "plan review failed; review state preserved"
        }
        if (planReviewUpdatePending) {
            planReviewUpdatePending = false
            status = "plan update failed; edit preserved"
        }
        dirtyPlanReview()
    }

    func cancelAgentTurn(): UpdateResult {
        if (planReviewDecisionPending) {
            planReviewDecisionPending = false
            status = "plan review cancelled; review state preserved"
        }
        if (planReviewUpdatePending) {
            planReviewUpdatePending = false
            status = "plan update cancelled; edit preserved"
        }
        dirtyPlanReview()
    }

    private func currentPlanReviewSection(): String {
        ensurePlanReviewDocument()
        var current = "Plan"
        for (section in planReviewSectionsCache where section.renderedLine <= documentScroll) {
            current = section.title
        }
        current
    }

    private func syncPlanReviewTocToScroll(): Unit {
        ensurePlanReviewDocument()
        var selected: Int64 = 0
        for (index in 0..planReviewSectionsCache.size where
            planReviewSectionsCache[index].renderedLine <= documentScroll) {
            selected = index
        }
        planReviewTocSelected = selected
    }

    private func ensurePlanReviewDocument(): Unit {
        let key = documentRevision.toString() + "|" + themeName
        if (planReviewDocumentCacheKey == key) {
            return
        }
        let theme = activeProductTheme(
            overrideName: themeName,
            customThemes: customThemeDefinitions
        )
        planReviewDocumentCache = markdownDocument(
            stripPlanReviewLabel(documentBody),
            theme: productMarkdownTheme(theme)
        )
        planReviewSectionsCache = planReviewSections(planReviewDocumentCache)
        planReviewDocumentCacheKey = key
        planReviewPreviewCacheKey = ""
        planReviewParseCount++
    }

    private func ensurePlanReviewPreview(width: Int64, visibleRows: Int64): Unit {
        ensurePlanReviewDocument()
        let safeWidth = max(1, width)
        let key = planReviewDocumentCacheKey + "|" + safeWidth.toString()
        if (planReviewPreviewCacheKey != key) {
            planReviewPreviewCache = markdownPreviewIndex(planReviewDocumentCache, safeWidth)
            for (section in planReviewSectionsCache) {
                section.renderedLine = planReviewPreviewCache.renderedLineForSourceOffset(section.sourceOffset)
            }
            planReviewPreviewCacheKey = key
        }
        planReviewVisibleRows = max(1, visibleRows)
        documentScroll = min(documentScroll, maximumPlanReviewScroll())
        planReviewTocSelected = min(
            max(0, planReviewSectionsCache.size - 1),
            max(0, planReviewTocSelected)
        )
    }

    private func maximumPlanReviewScroll(): Int64 {
        max(0, planReviewPreviewCache.renderedLineCount() - max(1, planReviewVisibleRows))
    }

    private func scrollPlanReviewBy(delta: Int64): Bool {
        let previous = documentScroll
        documentScroll = min(maximumPlanReviewScroll(), max(0, documentScroll + delta))
        documentScroll != previous
    }

    private func planReviewTocVisible(): Bool {
        planReviewTocArea.width > 0 && planReviewTocArea.height > 0 && planReviewSectionsCache.size >= 2
    }

    private func currentPlanReviewLineContext(): String {
        match (planReviewPreviewCache.sourceOffsetForRenderedLine(documentScroll)) {
            case Some(offset) => planReviewLineContextAtOffset(documentBody, offset)
            case None => ""
        }
    }

    private func dirtyPlanReview(): UpdateResult {
        if (activeModalArea.width > 0 && activeModalArea.height > 0) {
            UpdateResult.dirty(activeModalArea)
        } else {
            UpdateResult.next()
        }
    }

    private func planReviewFeedback(): String {
        if (planReviewAnnotations.isEmpty()) {
            return ""
        }
        var result = "Refinement feedback on the plan:\n"
        var currentSection = ""
        for (annotation in planReviewAnnotations) {
            if (annotation.section != currentSection) {
                currentSection = annotation.section
                result += "\n## " + currentSection + "\n"
            }
            if (annotation.line != "") {
                result += "> Line: " + annotation.line + "\n"
            }
            result += "- " + annotation.note.replace("\n", "\n  ") + "\n"
        }
        result
    }


    private func handlePlanReviewMouse(mouse: MouseEvent): UpdateResult {
        if (planReviewMode != "") {
            if (planReviewPointInRect(mouse.x, mouse.y, planReviewEditorArea) &&
                planReviewEditor.handleMouse(mouse, planReviewEditorArea)) {
                return dirtyPlanReview()
            }
            return UpdateResult.unchanged()
        }
        match ((mouse.kind, mouse.button)) {
            case (MouseKind.Scroll, MouseButton.WheelUp) =>
                return if (planReviewPointInRect(mouse.x, mouse.y, planReviewBodyArea) && scrollPlanReviewBy(-3)) {
                    dirtyPlanReview()
                } else {
                    UpdateResult.unchanged()
                }
            case (MouseKind.Scroll, MouseButton.WheelDown) =>
                return if (planReviewPointInRect(mouse.x, mouse.y, planReviewBodyArea) && scrollPlanReviewBy(3)) {
                    dirtyPlanReview()
                } else {
                    UpdateResult.unchanged()
                }
            case (MouseKind.Down, MouseButton.Left) =>
                if (planReviewPointInRect(mouse.x, mouse.y, planReviewActionsArea)) {
                    let selected = mouse.y - planReviewActionsArea.y
                    if (selected >= 0 && selected < 4) {
                        planReviewSelected = selected
                        planReviewFocus = PlanReviewFocus.Actions
                        status = planReviewFocusStatus(planReviewFocus)
                        return dirtyPlanReview()
                    }
                }
                if (planReviewPointInRect(mouse.x, mouse.y, planReviewTocArea)) {
                    let selected = planReviewTocStart + mouse.y - planReviewTocArea.y
                    if (selected >= 0 && selected < planReviewSectionsCache.size) {
                        planReviewTocSelected = selected
                        planReviewFocus = PlanReviewFocus.Toc
                        status = planReviewFocusStatus(planReviewFocus)
                        return dirtyPlanReview()
                    }
                }
                if (planReviewPointInRect(mouse.x, mouse.y, planReviewDocumentArea)) {
                    planReviewFocus = PlanReviewFocus.Body
                    status = planReviewFocusStatus(planReviewFocus)
                    return dirtyPlanReview()
                }
            case _ => ()
        }
        UpdateResult.unchanged()
    }


    private func renderPlanReviewOverlay(frame: Frame, theme: ProductTheme, terminalUnicode: Bool): Unit {
        let area = frame.area
        activeModalArea = area
        planReviewBodyArea = Rect(0, 0, 0, 0)
        planReviewTocArea = Rect(0, 0, 0, 0)
        planReviewTocStart = 0
        planReviewDocumentArea = Rect(0, 0, 0, 0)
        planReviewActionsArea = Rect(0, 0, 0, 0)
        planReviewEditorArea = Rect(0, 0, 0, 0)
        if (area.width <= 4 || area.height <= 4) {
            frame.canvas().drawText(
                area.x,
                area.y,
                cut("Plan Review", area.width),
                Style(fg: theme.accent, bg: theme.background, modifier: Modifier.strong())
            )
            return
        }
        let canvas = frame.canvas()
        let unicode = terminalUnicode
        let horizontal = if (unicode) { "─" } else { "-" }
        let vertical = if (unicode) { "│" } else { "|" }
        let topLeft = if (unicode) { "╭" } else { "+" }
        let topRight = if (unicode) { "╮" } else { "+" }
        let bottomLeft = if (unicode) { "╰" } else { "+" }
        let bottomRight = if (unicode) { "╯" } else { "+" }
        let title = if (planReviewMode == "edit") { "Edit Plan" } else { "Plan Review" }
        let titleText = topLeft + horizontal + " " + title + " "
        canvas.drawText(
            area.x,
            area.y,
            titleText + repeatedGlyph(horizontal, max(0, area.width - displayWidth(titleText) - 1)) + topRight,
            Style(fg: theme.muted, bg: theme.background)
        )
        canvas.drawText(
            area.x + 3,
            area.y,
            title,
            Style(fg: theme.accent, bg: theme.background, modifier: Modifier.strong())
        )
        for (y in (area.y + 1)..(area.bottom - 1)) {
            canvas.drawText(area.x, y, vertical, Style(fg: theme.muted, bg: theme.background))
            canvas.drawText(area.right - 1, y, vertical, Style(fg: theme.muted, bg: theme.background))
        }
        if (planReviewMode == "edit") {
            let editorArea = Rect(
                area.x + 1,
                area.y + 1,
                max(1, area.width - 2),
                max(1, area.height - 3)
            )
            planReviewEditorArea = editorArea
            frame.renderWidget(planReviewEditor, editorArea)
            let footer = status + " · Ctrl+S save · Esc return"
            drawPlanReviewBottomBorder(
                canvas,
                area,
                footer,
                theme,
                horizontal,
                bottomLeft,
                bottomRight
            )
            frame.setCursor(planReviewEditor.cursorPosition(editorArea))
            return
        }

        let annotationMode = planReviewMode == "annotate"
        let dividerY = if (annotationMode) {
            max(area.y + 3, area.bottom - 6)
        } else {
            max(area.y + 3, area.bottom - 7)
        }
        let bodyArea = Rect(
            area.x + 2,
            area.y + 1,
            max(1, area.width - 4),
            max(1, dividerY - area.y - 1)
        )
        renderPlanReviewBody(frame, bodyArea, theme, vertical)
        canvas.drawText(
            area.x,
            dividerY,
            vertical + repeatedGlyph(horizontal, max(0, area.width - 2)) + vertical,
            Style(fg: theme.muted, bg: theme.background)
        )

        if (annotationMode) {
            let caption = "Annotate " + planReviewAnnotationSection + if (planReviewAnnotationLine == "") {
                ""
            } else {
                " · " + planReviewAnnotationLine
            }
            canvas.drawText(
                area.x + 2,
                dividerY + 1,
                cut(caption, max(1, area.width - 4)),
                Style(fg: theme.accent, bg: theme.background, modifier: Modifier.strong())
            )
            let editorArea = Rect(
                area.x + 2,
                dividerY + 2,
                max(1, area.width - 4),
                max(1, area.bottom - dividerY - 3)
            )
            planReviewEditorArea = editorArea
            frame.renderWidget(planReviewEditor, editorArea)
            drawPlanReviewBottomBorder(
                canvas,
                area,
                status + " · Ctrl+S save · Esc return",
                theme,
                horizontal,
                bottomLeft,
                bottomRight
            )
            frame.setCursor(planReviewEditor.cursorPosition(editorArea))
            return
        }

        canvas.drawText(
            area.x + 2,
            dividerY + 1,
            cut(
                "Plan mode · next step" + if (planReviewAnnotations.isEmpty()) {
                    ""
                } else {
                    " · " + planReviewAnnotations.size.toString() + " note(s)"
                } + " · " + status,
                max(1, area.width - 4)
            ),
            Style(fg: theme.secondary, bg: theme.background, modifier: Modifier.strong())
        )
        let options = planReviewActionLabels()
        planReviewActionsArea = Rect(
            area.x + 2,
            dividerY + 2,
            max(1, area.width - 4),
            min(4, max(0, area.bottom - dividerY - 3))
        )
        for (index in 0..options.size) {
            let active = index == planReviewSelected
            let marker = if (active) { "› " } else { "  " }
            canvas.drawText(
                area.x + 2,
                dividerY + 2 + index,
                cut(marker + options[index], max(1, area.width - 4)),
                Style(
                    fg: if (active && planReviewFocus == PlanReviewFocus.Actions) {
                        theme.accent
                    } else if (active) {
                        theme.secondary
                    } else {
                        theme.text
                    },
                    bg: theme.background,
                    modifier: if (active) { Modifier.strong() } else { Modifier.none() }
                )
            )
        }
        drawPlanReviewBottomBorder(
            canvas,
            area,
            planReviewHelp(planReviewFocus),
            theme,
            horizontal,
            bottomLeft,
            bottomRight
        )
    }

    private func renderPlanReviewBody(
        frame: Frame,
        area: Rect,
        theme: ProductTheme,
        vertical: String
    ): Unit {
        planReviewBodyArea = area
        ensurePlanReviewDocument()
        let sections = planReviewSectionsCache
        let sidebar = sections.size >= 2 && area.width >= 64
        let sidebarWidth = if (sidebar) {
            min(30, max(18, area.width / 4))
        } else {
            0
        }
        planReviewTocArea = if (sidebar) {
            Rect(area.x, area.y, sidebarWidth, area.height)
        } else {
            Rect(0, 0, 0, 0)
        }
        if (!sidebar && planReviewFocus == PlanReviewFocus.Toc) {
            planReviewFocus = PlanReviewFocus.Body
            status = planReviewFocusStatus(planReviewFocus)
        }
        let documentArea = Rect(
            area.x + if (sidebar) { sidebarWidth + 2 } else { 0 },
            area.y,
            max(1, area.width - if (sidebar) { sidebarWidth + 2 } else { 0 }),
            area.height
        )
        planReviewDocumentArea = documentArea
        ensurePlanReviewPreview(documentArea.width, documentArea.height)
        let currentSection = currentPlanReviewSection()
        if (sidebar) {
            let sidebarArea = planReviewTocArea
            let visible = min(sections.size, sidebarArea.height)
            var start: Int64 = 0
            if (sections.size > visible) {
                start = min(
                    sections.size - visible,
                    max(0, planReviewTocSelected - visible / 2)
                )
            }
            planReviewTocStart = start
            for (row in 0..visible) {
                let index = start + row
                let section = sections[index]
                let selected = index == planReviewTocSelected
                let current = section.title == currentSection
                let annotated = planReviewSectionAnnotated(section.title)
                let marker = if (selected && planReviewFocus == PlanReviewFocus.Toc) {
                    "›"
                } else if (current) {
                    "▎"
                } else {
                    " "
                }
                let indentation = repeatedGlyph(" ", max(0, section.level - 1))
                let suffix = if (annotated) { " ✎" } else { "" }
                frame.canvas().drawText(
                    sidebarArea.x,
                    sidebarArea.y + row,
                    cut(marker + indentation + section.title + suffix, sidebarArea.width - 1),
                    if (selected && planReviewFocus == PlanReviewFocus.Toc) {
                        Style(fg: theme.accent, bg: theme.background, modifier: Modifier.strong())
                    } else if (current) {
                        Style(fg: theme.accent, bg: theme.background)
                    } else {
                        Style(fg: theme.muted, bg: theme.background)
                    }
                )
            }
            for (row in 0..area.height) {
                frame.canvas().drawText(
                    area.x + sidebarWidth,
                    area.y + row,
                    vertical,
                    Style(fg: theme.muted, bg: theme.background)
                )
            }
        }
        frame.renderWidget(
            CachedDocumentViewport(
                planReviewWindowCache,
                planReviewDocumentCache,
                planReviewDocumentCacheKey,
                documentScroll
            ),
            documentArea
        )
    }

    private func planReviewSectionAnnotated(section: String): Bool {
        for (annotation in planReviewAnnotations where annotation.section == section) {
            return true
        }
        false
    }

}
