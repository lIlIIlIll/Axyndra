package agent_tui

import core.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class TodoPendingReviewTests {
    @TestCase
    func pendingApprovalHidesOnlyEditorPresentationAndPreservesItsExactDraft():Unit {
        let controller=TodoController()
        let _=controller.open(TuiTodoLoadResult(true,"# Draft\n- [ ] original\n","loaded"))
        let _=controller.paste("- [ ] unsaved\n")
        let before=controller.captureProbeState().editorValue
        let _=controller.updateKey(KeyEvent(KeyCode.Char(r's'),modifiers:KeyModifier(ctrl:true)))
        let _=controller.acceptSave(TuiTodoSaveResult(false,"awaiting actual approval"))
        @Expect(controller.isEditing())
        @Expect(!controller.editorVisible(true))
        @Expect(controller.captureProbeState().editorValue,before)
        // Rejection/cancellation clears the existing approval card; the same
        // untouched editor is visible again without a new backend read.
        @Expect(controller.editorVisible(false))
        @Expect(controller.captureProbeState().editorValue,before)
        let _=controller.acceptSave(TuiTodoSaveResult(true,"actual CAS completed"))
        @Expect(!controller.editorVisible(false))
    }
}
