package agent_product

import agent_domain.*
import tool_runtime.ApprovalMode
import agent_store.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class TodoEditorApprovalTests {
    @TestCase
    func actualEditorReadAndSaveResumeTheirOriginalRunsWithoutDisplayCreatingWork():Unit {
        let f=TodoNativeFrontendFixture("editor-review",mode:ApprovalMode.AlwaysAsk)
        try{
            @Expect(f.session.todoMarkdown().value().getOrThrow(),"# Todos\n")
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),0)
            @Expect(f.session.loadTodoEditor().isError())
            @Expect(f.session.takeTodoEditorCompletion().isNone())
            let read=f.session.approval().getOrThrow()
            @Expect(read.toolName,HOST_CONTEXT_READ_TOOL)
            let readRun=f.database.query("SELECT run_id FROM operations WHERE id=?",[SqlParameter.Text(read.operationId.value)])[0].required(0)
            @Expect(f.session.todoMarkdown().isOk())
            @Expect(f.session.approval().getOrThrow().operationId.value,read.operationId.value)
            let next=f.session.handle("/approve "+read.operationId.value).value().getOrThrow().approval.getOrThrow()
            @Expect(next.operationId.value!=read.operationId.value)
            @Expect(f.database.query("SELECT run_id FROM operations WHERE id=?",[SqlParameter.Text(next.operationId.value)])[0].required(0),readRun)
            @Expect(f.session.handle("/approve "+next.operationId.value).value().getOrThrow().approval.isNone())
            let loaded=f.session.takeTodoEditorCompletion().getOrThrow()
            @Expect(!loaded.saved);@Expect(loaded.markdown,"# Todos\n")
            @Expect(f.session.takeTodoEditorCompletion().isNone())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),1)
            @Expect(f.session.replaceTodoMarkdown("# Approved\n- [ ] retained editor\n").isOk())
            let saveRead=f.session.approval().getOrThrow()
            @Expect(f.document().revision,0)
            @Expect(f.session.takeTodoEditorCompletion().isNone())
            let saveRun=f.database.query("SELECT run_id FROM operations WHERE id=?",[SqlParameter.Text(saveRead.operationId.value)])[0].required(0)
            let save=f.session.handle("/approve "+saveRead.operationId.value).value().getOrThrow().approval.getOrThrow()
            @Expect(f.database.query("SELECT run_id FROM operations WHERE id=?",[SqlParameter.Text(save.operationId.value)])[0].required(0),saveRun)
            @Expect(f.session.todoMarkdown().value().getOrThrow(),"# Todos\n")
            @Expect(f.session.handle("/approve "+save.operationId.value).value().getOrThrow().approval.isNone())
            let completed=f.session.takeTodoEditorCompletion().getOrThrow()
            @Expect(completed.saved);@Expect(completed.markdown.contains("retained editor"))
            @Expect(f.document().revision,1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),2)
            @Expect(f.session.todoMarkdown().value().getOrThrow(),completed.markdown)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),2)
            f.noModel()
        }finally{f.close()}
    }

    @TestCase
    func rejectedAndCancelledEditorReadsNeverPublishCompletionOrReplaceState():Unit {
        for(cancelled in [false,true]){
            let f=TodoNativeFrontendFixture(if(cancelled){"editor-cancel"}else{"editor-reject"},mode:ApprovalMode.AlwaysAsk)
            try{
                @Expect(f.session.loadTodoEditor().isError())
                let waiting=f.session.approval().getOrThrow()
                if(cancelled){@Expect(f.session.cancel().isOk())}
                else{let rejected=f.session.handle("/reject "+waiting.operationId.value)
                    @Expect(rejected.isError());@Expect(rejected.error().getOrThrow().code,"context.read_rejected")}
                @Expect(f.session.takeTodoEditorCompletion().isNone())
                @Expect(f.session.approval().isNone())
                @Expect(f.session.replaceTodoMarkdown("# forbidden\n- [ ] write\n").isError())
                @Expect(f.document().revision,0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"),0)
                f.noModel()
            }finally{f.close()}}
    }

    @TestCase
    func readonlyDisplayMatchesNativeMarkersWithoutChangingEditorDigest():Unit {
        let f=TodoNativeFrontendFixture("editor-display")
        try{
            @Expect(f.session.setTodoPhases([ProductTodoPhase("All markers",[
                ProductTodoItem("pending"),ProductTodoItem("active",status:ProductTodoStatus.InProgress),
                ProductTodoItem("done",status:ProductTodoStatus.Completed),ProductTodoItem("dropped",status:ProductTodoStatus.Abandoned),
                ProductTodoItem("blocked",status:ProductTodoStatus.Blocked,blocker:"a --> b\r\nnext")])]).isOk())
            let native=f.session.loadTodoEditor().value().getOrThrow()
            let runs=f.database.scalarInt("SELECT COUNT(*) FROM runs")
            @Expect(f.session.todoMarkdown().value().getOrThrow(),native)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),runs)
            let other=f.product.applicationSession(sessionId:Some(f.session.id()))
            @Expect(other.setTodoPhases([ProductTodoPhase("New",[ProductTodoItem("current")])]).isOk())
            @Expect(f.session.todoMarkdown().value().getOrThrow().contains("# New"))
            let before=f.document()
            @Expect(f.session.replaceTodoMarkdown(native).isError())
            @Expect(f.document().revision,before.revision);@Expect(f.document().encoded,before.encoded)
            f.noModel()
        }finally{f.close()}
    }
}
