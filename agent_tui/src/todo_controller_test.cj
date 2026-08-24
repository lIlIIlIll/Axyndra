package agent_tui

import core.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class TodoControllerTests {
    @TestCase
    func parserPrioritizesActiveAndBlockedItems(): Unit {
        let items = parseTodoItems(
            "- [x] complete\n" +
                "- [ ] queued\n" +
                "- [/] active\n" +
                "- [!] blocked <!-- blocker: fixture -->\n"
        )
        @Expect(items.size, 4)
        @Expect(items[3].content, "blocked")

        let visible = visibleTodoItems(items, 2)
        @Expect(visible.size, 2)
        @Expect(visible[0].marker, "/")
        @Expect(visible[1].marker, "!")
        @Expect(todoRowCount(items.size, 60, 18, 0), 2)
    }

    @TestCase
    func editorSaveFailurePreservesDraftAndReopens(): Unit {
        let controller = TodoController()
        let opened = controller.open(
            TuiTodoLoadResult(true, "- [ ] original\n", "loaded")
        )
        @Expect(controller.isEditing())
        @Expect(opened.layoutChanged)

        let _ = controller.paste("- [/] follow-up\n")
        let save = controller.updateKey(
            KeyEvent(
                KeyCode.Char(r's'),
                modifiers: KeyModifier(ctrl: true)
            )
        )
        @Expect(!controller.isEditing())
        match (save.effect) {
            case Some(TodoEffect.SaveMarkdown(markdown)) =>
                @Expect(markdown.contains("follow-up"))
            case _ => @Fail("Ctrl+S must emit SaveMarkdown")
        }

        let failed = controller.acceptSave(TuiTodoSaveResult(false, "save failed"))
        @Expect(controller.isEditing())
        @Expect(controller.captureProbeState().editorValue.contains("follow-up"))
        match (failed.status) {
            case Some(value) => @Expect(value, "save failed")
            case None => @Fail("save failure must surface status")
        }

        let cancelled = controller.updateKey(KeyEvent(KeyCode.Esc))
        @Expect(!controller.isEditing())
        match (cancelled.status) {
            case Some(value) => @Expect(value, "todo edit cancelled")
            case None => @Fail("cancel must surface status")
        }
    }

    @TestCase
    func editorOwnsMouseWhileOverlayIsOpen(): Unit {
        let controller = TodoController()
        let _ = controller.open(
            TuiTodoLoadResult(true, "- [ ] first\n- [ ] second\n", "loaded")
        )
        let area = Rect(0, 0, 80, 24)
        controller.renderEditor(Frame(area, Buffer(area)), ompTheme())

        let click = controller.updateMouse(
            MouseEvent(MouseKind.Down, MouseButton.Left, 8, 5)
        )
        @Expect(click.update.renderRequested)

        let wheel = controller.updateMouse(
            MouseEvent(MouseKind.Scroll, MouseButton.WheelUp, 8, 5)
        )
        @Expect(!wheel.update.renderRequested)

        let outside = controller.updateMouse(
            MouseEvent(MouseKind.Down, MouseButton.Left, 0, 0)
        )
        @Expect(!outside.update.renderRequested)
    }
}
