package agent_tui

import core.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class AskControllerTests {
    @TestCase
    func tabFromAnyChoiceOpensAndSubmitsCustomText(): Unit {
        let controller = AskController()
        @Assert(controller.begin(singleQuestionRequest()))

        let opened = controller.updateKey(KeyEvent(KeyCode.Tab))
        @Expect(opened.changed)
        @Expect(opened.cardChanged)
        @Expect(controller.editorActive())
        @Expect(controller.probeSnapshot().cursor, 1)
        @Expect(controller.probeSnapshot().editorMode, "custom")
        @Expect(controller.statusText(), "custom answer · Enter save · Esc cancel")
        match (controller.currentPresentation()) {
            case Some(presentation) =>
                @Expect(presentation.body.contains("› Other: "))
                @Expect(presentation.footer.contains("Enter save · Esc cancel"))
            case None => @Fail("inline custom editor must keep the Ask card visible")
        }

        let _ = controller.paste("Run the\nportable contract")
        let typed = controller.updateEditor(KeyEvent(KeyCode.Char(r'!')))
        @Expect(typed.changed)
        @Expect(!typed.cardChanged)

        let area = Rect(0, 0, 80, 24)
        let cardArea = Rect(2, 1, 70, 6)
        let buffer = Buffer(area)
        controller.renderEditor(
            Frame(area, buffer),
            axyndraTheme(),
            cardArea: Some(cardArea)
        )
        let inputX = cardArea.x + 2 + displayWidth("› Other: ")
        @Expect(buffer.getCell(inputX, 4).symbol, "R")

        let clippedCardArea = Rect(2, 1, 70, 2)
        let clippedBuffer = Buffer(area)
        controller.renderEditor(
            Frame(area, clippedBuffer),
            axyndraTheme(),
            cardArea: Some(clippedCardArea),
            fallbackArea: Some(area)
        )
        @Expect(clippedBuffer.getCell(clippedCardArea.x + 2, clippedCardArea.bottom - 1).symbol, "›")
        @Expect(clippedBuffer.getCell(inputX, clippedCardArea.bottom - 1).symbol, "R")

        let submitted = controller.updateEditor(KeyEvent(KeyCode.Enter))
        @Expect(!controller.editorActive())
        match (submitted.effect) {
            case Some(AskEffect.Submit(_, TuiAskResolution.Answers(values))) =>
                @Assert(values.size, 1)
                @Expect(values[0].selectedOptions.isEmpty())
                @Expect(match (values[0].customInput) {
                    case Some(value) => value == "Run the portable contract!"
                    case None => false
                })
            case _ => @Fail("Tab custom answer must be submitted")
        }
    }

    @TestCase
    func multiCustomTextStaysInlineUntilDone(): Unit {
        let controller = AskController()
        @Assert(controller.begin(multiQuestionRequest()))

        let _ = controller.updateKey(KeyEvent(KeyCode.Char(r' ')))
        let _ = controller.updateKey(KeyEvent(KeyCode.Down))
        let _ = controller.updateKey(KeyEvent(KeyCode.Down))
        let _ = controller.updateKey(KeyEvent(KeyCode.Tab))
        let _ = controller.paste("Portable archive")
        let saved = controller.updateEditor(KeyEvent(KeyCode.Enter))

        @Expect(saved.effect.isNone())
        @Expect(saved.cardChanged)
        @Expect(!controller.editorActive())
        match (controller.currentPresentation()) {
            case Some(presentation) =>
                @Expect(presentation.body.contains("[x] Export"))
                @Expect(presentation.body.contains("Other (type your own): Portable archive"))
            case None => @Fail("multi-select must remain on the current question until Done")
        }

        let _ = controller.updateKey(KeyEvent(KeyCode.Down))
        let submitted = controller.updateKey(KeyEvent(KeyCode.Enter))
        match (submitted.effect) {
            case Some(AskEffect.Submit(_, TuiAskResolution.Answers(values))) =>
                @Assert(values.size, 1)
                @Expect(values[0].selectedOptions, ["Export"])
                @Expect(match (values[0].customInput) {
                    case Some(value) => value == "Portable archive"
                    case None => false
                })
            case _ => @Fail("Done must submit both selected options and custom text")
        }
    }

    @TestCase
    func enterStillOpensInlineCustomAndEscapeCancelsTheEdit(): Unit {
        let controller = AskController()
        @Assert(controller.begin(singleQuestionRequest()))
        let _ = controller.updateKey(KeyEvent(KeyCode.Down))

        let opened = controller.updateKey(KeyEvent(KeyCode.Enter))
        @Expect(opened.cardChanged)
        @Expect(controller.editorActive())
        let closed = controller.updateEditor(KeyEvent(KeyCode.Esc))
        @Expect(closed.cardChanged)
        @Expect(!controller.editorActive())
        match (controller.currentPresentation()) {
            case Some(presentation) => @Expect(presentation.body.contains("› Other (type your own)"))
            case None => @Fail("Esc must return to the active Ask card")
        }
    }

    @TestCase
    func restoredCustomTextDoesNotLeakIntoSingleOptionAnswer(): Unit {
        let controller = AskController()
        @Assert(controller.begin(twoQuestionRequest()))
        let _ = controller.updateKey(KeyEvent(KeyCode.Down))
        let _ = controller.updateKey(KeyEvent(KeyCode.Tab))
        let _ = controller.paste("Keep this custom answer")
        let _ = controller.updateEditor(
            KeyEvent(KeyCode.Char(r's'), modifiers: KeyModifier(ctrl: true))
        )

        let _ = controller.updateKey(KeyEvent(KeyCode.Left))
        @Expect(controller.probeSnapshot().cursor, 1)
        let _ = controller.updateKey(KeyEvent(KeyCode.Tab))
        let reopened = controller.updateEditor(
            KeyEvent(KeyCode.Char(r's'), modifiers: KeyModifier(ctrl: true))
        )
        @Expect(reopened.changed)
        @Expect(!controller.editorActive())

        let _ = controller.updateKey(KeyEvent(KeyCode.Left))
        let _ = controller.updateKey(KeyEvent(KeyCode.Up))
        let _ = controller.updateKey(KeyEvent(KeyCode.Enter))
        let submitted = controller.updateKey(KeyEvent(KeyCode.Enter))
        match (submitted.effect) {
            case Some(AskEffect.Submit(_, TuiAskResolution.Answers(values))) =>
                @Assert(values.size, 2)
                @Expect(values[0].selectedOptions, ["Run unit tests"])
                @Expect(values[0].customInput.isNone())
            case _ => @Fail("ordinary single option must replace restored custom text")
        }
    }

    @TestCase
    func rejectedAnswerRemainsExpandedAndRetriesWithoutDuplication(): Unit {
        let controller = AskController()
        @Assert(controller.begin(twoQuestionRequest()))
        let _ = controller.updateKey(KeyEvent(KeyCode.Enter))
        let firstAttempt = controller.updateKey(KeyEvent(KeyCode.Enter))

        match (firstAttempt.effect) {
            case Some(AskEffect.Submit(_, resolution)) =>
                match (controller.completeSubmission(false, resolution)) {
                    case Some(completion) =>
                        @Expect(completion.state, "awaiting")
                        @Expect(!completion.collapsed)
                        @Expect(completion.footer.contains("retry or edit"))
                    case None => @Fail("rejected Ask submission must restore an interactive card")
                }
            case None => @Fail("the final answer must reach the backend")
        }

        let retry = controller.updateKey(KeyEvent(KeyCode.Enter))
        match (retry.effect) {
            case Some(AskEffect.Submit(_, TuiAskResolution.Answers(values))) =>
                @Assert(values.size, 2)
                @Expect(values[0].selectedOptions, ["Run unit tests"])
                @Expect(values[1].selectedOptions, ["Keep local"])
            case _ => @Fail("retry must submit exactly one answer per question")
        }
    }

    @TestCase
    func editorTypingOnlyInvalidatesTheEditor(): Unit {
        let controller = AskController()
        @Assert(controller.begin(singleQuestionRequest()))
        let opened = controller.updateKey(KeyEvent(KeyCode.Char(r'n')))
        @Expect(opened.changed)
        @Expect(!opened.cardChanged)

        let typed = controller.updateEditor(KeyEvent(KeyCode.Char(r'x')))
        @Expect(typed.changed)
        @Expect(!typed.cardChanged)

        let saved = controller.updateEditor(
            KeyEvent(
                KeyCode.Char(r's'),
                modifiers: KeyModifier(ctrl: true)
            )
        )
        @Expect(saved.changed)
        @Expect(saved.cardChanged)
        @Expect(!controller.editorActive())
    }

    @TestCase
    func editorOwnsClickAndDragButSwallowsWheelAndOutsideMouse(): Unit {
        let controller = AskController()
        @Assert(controller.begin(singleQuestionRequest()))
        let _ = controller.updateKey(KeyEvent(KeyCode.Char(r'n')))
        let _ = controller.paste("portable verification")
        let area = Rect(0, 0, 80, 24)
        controller.renderEditor(Frame(area, Buffer(area)), axyndraTheme())

        let click = controller.updateMouse(
            MouseEvent(MouseKind.Down, MouseButton.Left, 4, 3)
        )
        @Expect(click.renderRequested)
        let drag = controller.updateMouse(
            MouseEvent(MouseKind.Drag, MouseButton.Left, 10, 3)
        )
        @Expect(drag.renderRequested)

        let wheel = controller.updateMouse(
            MouseEvent(MouseKind.Scroll, MouseButton.WheelUp, 4, 3)
        )
        @Expect(!wheel.renderRequested)
        let outside = controller.updateMouse(
            MouseEvent(MouseKind.Down, MouseButton.Left, 0, 0)
        )
        @Expect(!outside.renderRequested)

        let _ = controller.updateEditor(KeyEvent(KeyCode.Esc))
        @Expect(!controller.updateMouse(
            MouseEvent(MouseKind.Down, MouseButton.Left, 4, 3)
        ).renderRequested)
    }

    @TestCase
    func presentationAndProbeExposeReadOnlyInteractionState(): Unit {
        let controller = AskController()
        @Assert(controller.begin(singleQuestionRequest()))
        match (controller.currentPresentation()) {
            case Some(presentation) =>
                @Expect(presentation.request.requestId, "ask-controller-test")
                @Expect(presentation.title.contains("Verification"))
                @Expect(presentation.body.contains("Run unit tests"))
                @Expect(presentation.footer.contains("1/1"))
            case None => @Fail("active Ask must expose a presentation")
        }

        let _ = controller.updateKey(KeyEvent(KeyCode.Char(r'n')))
        let _ = controller.paste("Prefer the portable path")
        let _ = controller.updateEditor(
            KeyEvent(
                KeyCode.Char(r's'),
                modifiers: KeyModifier(ctrl: true)
            )
        )
        let submission = controller.updateKey(KeyEvent(KeyCode.Enter))
        match (submission.effect) {
            case Some(AskEffect.Submit(_, TuiAskResolution.Answers(values))) =>
                @Expect(values.size, 1)
            case _ => @Fail("single choice must submit its answer")
        }

        let snapshot = controller.probeSnapshot()
        @Expect(snapshot.submissionAttempted)
        @Expect(!snapshot.submissionAccepted)
        @Expect(snapshot.submissionNote, "Prefer the portable path")
        @Expect(snapshot.editorMode, "")
        @Expect(snapshot.active)
        @Expect(snapshot.cursor, 0)
        @Expect(snapshot.status.contains("1/1"))
    }

    @TestCase
    func opaqueProbeStateRestoresEditorAndInteractionState(): Unit {
        let controller = AskController()
        @Assert(controller.begin(singleQuestionRequest()))
        let _ = controller.updateKey(KeyEvent(KeyCode.Down))
        let _ = controller.updateKey(KeyEvent(KeyCode.Char(r'n')))
        let _ = controller.paste("restored note")
        let area = Rect(0, 0, 80, 24)
        controller.renderEditor(Frame(area, Buffer(area)), axyndraTheme())
        let saved = controller.captureProbeState()

        let _ = controller.updateEditor(KeyEvent(KeyCode.Esc))
        let _ = controller.updateKey(KeyEvent(KeyCode.Up))
        controller.restoreProbeState(saved)

        let restored = controller.probeSnapshot()
        @Expect(restored.active)
        @Expect(restored.cursor, 1)
        @Expect(restored.editorMode, "note")
        @Expect(restored.status, "ask note · Ctrl+S save · Esc return")
        @Expect(controller.updateMouse(
            MouseEvent(MouseKind.Down, MouseButton.Left, 4, 3)
        ).renderRequested)

        let savedNote = controller.updateEditor(
            KeyEvent(
                KeyCode.Char(r's'),
                modifiers: KeyModifier(ctrl: true)
            )
        )
        @Expect(savedNote.cardChanged)
        let _ = controller.updateKey(KeyEvent(KeyCode.Up))
        let _ = controller.updateKey(KeyEvent(KeyCode.Enter))
        @Expect(controller.probeSnapshot().submissionNote, "restored note")
    }

    private func singleQuestionRequest(): TuiAskRequest {
        TuiAskRequest(
            "ask-controller-test",
            [
                TuiAskQuestion(
                    "verification",
                    "Which verification should run?",
                    [TuiAskOption("Run unit tests")],
                    header: "Verification",
                    recommended: 0
                )
            ]
        )
    }

    private func twoQuestionRequest(): TuiAskRequest {
        TuiAskRequest(
            "ask-controller-two-question-test",
            [
                TuiAskQuestion(
                    "verification",
                    "Which verification should run?",
                    [TuiAskOption("Run unit tests")],
                    header: "Verification",
                    recommended: 0
                ),
                TuiAskQuestion(
                    "delivery",
                    "How should the result be delivered?",
                    [TuiAskOption("Keep local")],
                    header: "Delivery",
                    recommended: 0
                )
            ]
        )
    }

    private func multiQuestionRequest(): TuiAskRequest {
        TuiAskRequest(
            "ask-controller-multi-question-test",
            [
                TuiAskQuestion(
                    "features",
                    "Which features should be enabled?",
                    [TuiAskOption("Export"), TuiAskOption("Import")],
                    header: "Features",
                    multi: true,
                    recommended: 0
                )
            ]
        )
    }
}
