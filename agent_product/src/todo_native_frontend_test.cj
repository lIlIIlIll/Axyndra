package agent_product

import agent_domain.*
import agent_plugin_registry
import agent_store.*
import tool_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class TodoNativeFrontendFixture {
    let root: String
    let product: ProductRuntime
    let database: SqliteDatabase
    let record: ProductPluginRecord
    let session: ApplicationSession
    init(label:String,mode!:ApprovalMode=ApprovalMode.Yolo,resources!:Bool=false){
        let root=pluginContractTemp("todo-native-"+label)
        Directory.create(root+"/workspace",recursive:true)
        let product=workspacePluginOpen(root,mode)
        let record=todoTestInstallNative(product)
        if(resources){let workspace=workspacePluginInstall(product,root);workspaceFrontendConfigure(root,workspace)}
        let session=product.applicationSession(sessionId:Some(SessionId("todo-"+label)))
        this.root=root;this.product=product;this.record=record;this.session=session
        database=SqliteDatabase(root+"/state/state.db")
    }
    func document(): PluginDocumentSnapshot {
        lifecycleTestRequire(SqlitePluginDocumentRepository(database).read(ThreadId(session.id().value),LaneId("main"),productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)),"todo"))
    }
    func cold(): String {
        let rows=database.query("SELECT todo_payload FROM thread_metadata WHERE thread_id=?",[SqlParameter.Text(session.id().value)])
        if(rows.isEmpty()){ "" }else{rows[0].required(0)}
    }
    func rejectCount(): Int64 {database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='rejected'")}
    func noModel(): Unit {
        @Expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts"),0)
        @Expect(database.scalarInt("SELECT COUNT(*) FROM model_decisions"),0)
    }
    func close(): Unit {
        let _=session.cancel();record.close();database.close();let _=product.close();remove(root,recursive:true)
    }
}

@Test
class TodoNativeFrontendTests {
    @TestCase
    func missingSelectionAndRetiredStaticToolNeverWriteColdOrCurrentState(): Unit {
        let root=pluginContractTemp("todo-no-default");Directory.create(root+"/workspace",recursive:true)
        let product=workspacePluginOpen(root,ApprovalMode.Yolo);let database=SqliteDatabase(root+"/state/state.db")
        try{
            let session=product.applicationSession(sessionId:Some(SessionId("todo-no-default")))
            @Expect(product.vnext.publishedToolIdentity("todo",threadId:Some(ThreadId(session.id().value))).isNone())
            @Expect(session.handle("/todo append Work forbidden").isError())
            @Expect(session.todoPhases().isError())
            @Expect(database.scalarInt("SELECT COUNT(*) FROM runs"),0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operations"),0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM plugin_documents"),0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts"),0)
        }finally{database.close();let _=product.close();remove(root,recursive:true)}
    }
    @TestCase
    func realNativeSlashWritesOnlyTheSelectedDocumentAndReadonlyProjection(): Unit {
        let f=TodoNativeFrontendFixture("slash")
        try{
            let cold=f.cold()
            @Expect(f.session.handle("/todo append Work verify").isOk())
            let state=f.session.todoPhases().value().getOrThrow()
            @Expect(state.size,1);@Expect(state[0].name,"Work");@Expect(state[0].tasks.size,1)
            @Expect(state[0].tasks[0].content,"Verify")
            @Expect(f.document().revision,1);@Expect(f.cold(),cold)
            let before=f.database.scalarInt("SELECT COUNT(*) FROM operations")
            @Expect(f.product.todoPhases(f.session.id()).value().getOrThrow()[0].name,"Work")
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),before)
            @Expect(f.product.vnext.publishedToolIdentity("plugin."+productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace))+".todo",threadId:Some(ThreadId(f.session.id().value))).getOrThrow().implementationVersion,
                f.product.vnext.javascriptPlugins.instanceExecutorVersion(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)),f.product.vnext.javascriptPlugins.instanceGeneration(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)))).value().getOrThrow())
            f.noModel()
        }finally{f.close()}
    }
    @TestCase
    func nativeEditorRejectsAnActualConcurrentDocumentRevisionWithoutOverwrite(): Unit {
        let f=TodoNativeFrontendFixture("conflict")
        try{
            @Expect(f.session.handle("/todo append Work first").isOk())
            @Expect(f.session.loadTodoEditor().isOk())
            let other=f.product.applicationSession(sessionId:Some(f.session.id()))
            @Expect(other.setTodoPhases([ProductTodoPhase("Actual other",[ProductTodoItem("keep")])]).isOk())
            @Expect(f.session.todoMarkdown().value().getOrThrow().contains("Actual other"))
            let before=f.document()
            @Expect(f.session.replaceTodoMarkdown("# Attempted\n- [ ] overwrite\n").isError())
            @Expect(f.document().revision,before.revision);@Expect(f.document().encoded,before.encoded)
            @Expect(f.session.todoPhases().value().getOrThrow()[0].name,"Actual other")
            f.noModel()
        }finally{f.close()}
    }
    @TestCase
    func unitSetterExposesActualPendingReviewAndRejectLeavesTheDocumentEmpty(): Unit {
        let f=TodoNativeFrontendFixture("pending",mode:ApprovalMode.AlwaysAsk)
        try{
            let cold=f.cold()
            let result=f.session.setTodoPhases([ProductTodoPhase("Pending",[ProductTodoItem("forbidden until approval")])])
            @Expect(result.isError());@Expect(result.error().getOrThrow().kind,AgentErrorKind.PermissionDenied)
            let request=f.session.approval().getOrThrow()
            @Expect(result.error().getOrThrow().fields[0].value,request.operationId.value)
            @Expect(f.document().revision,0);@Expect(f.cold(),cold)
            let _=f.session.handle("/reject "+request.operationId.value)
            @Expect(f.document().revision,0);@Expect(f.cold(),cold)
            // The actual pending ContextRead and its original Direct parent
            // each settle their own reserved Receipt. Neither was handed off.
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts r JOIN operation_effect_records e " +
                "ON e.operation_id=r.operation_id WHERE r.operation_id="+sqliteText(request.operationId.value)+
                " AND r.id=e.reserved_receipt_id AND r.outcome='rejected' AND e.tool_id="+sqliteText(HOST_CONTEXT_READ_TOOL)),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts r JOIN operation_effect_records e " +
                "ON e.operation_id=r.operation_id JOIN audit_events a ON a.operation_id=r.operation_id AND a.run_id=e.run_id " +
                "WHERE a.kind='operation_direct_preparation_rejection_only' AND r.id=e.reserved_receipt_id " +
                "AND r.outcome='rejected' AND e.tool_id="+sqliteText("plugin."+productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace))+".todo")+
                " AND e.run_id=(SELECT run_id FROM operations WHERE id="+sqliteText(request.operationId.value)+")"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff' " +
                "AND run_id=(SELECT run_id FROM operations WHERE id="+sqliteText(request.operationId.value)+")"),0)
            @Expect(f.session.approval().isNone());f.noModel()
        }finally{f.close()}
    }
    @TestCase
    func uriImportRequiresIndependentReadRootsThenANewCanonicalDocumentCommit(): Unit {
        let f=TodoNativeFrontendFixture("uri-import",resources:true)
        let uri=WorkspaceFrontendUri(content:"# Actual URI\n- [ ] Imported snow 雪\n")
        try{
            @Expect(f.product.registerUriHandler("memory",uri).isOk())
            @Expect(f.session.handle("/todo import memory://todo").isOk())
            @Expect(uri.readCount(),0);@Expect(f.document().revision,0)
            @Expect(f.session.handle("/todo commit").isError())
            @Expect(f.session.handle("/todo resource").isOk())
            @Expect(uri.readCount(),0);@Expect(f.document().revision,0)
            @Expect(f.session.handle("/todo resource").isOk())
            @Expect(uri.readCount(),1);@Expect(uri.writeCount(),0);@Expect(f.document().revision,0)
            @Expect(f.session.handle("/todo commit").isOk())
            @Expect(f.document().revision,1);@Expect(f.session.todoPhases().value().getOrThrow()[0].name,"Actual URI")
            @Expect(uri.readCount(),1);@Expect(uri.writeCount(),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs")>=4)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','running')"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'")>=4)
            f.noModel()
        }finally{f.close()}
    }
    @TestCase
    func exportCreatesBytesOnlyThroughItsIndependentResourceRoot(): Unit {
        let f=TodoNativeFrontendFixture("file-export",resources:true)
        try{
            @Expect(f.session.handle("/todo append Actual save").isOk())
            let before=f.document();let destination=f.root+"/workspace/exported.md"
            @Expect(f.session.handle("/todo export exported.md").isOk())
            @Expect(!exists(Path(destination)));@Expect(f.document().encoded,before.encoded)
            @Expect(f.session.handle("/todo resource").isOk())
            @Expect(String.fromUtf8(File.readFrom(destination)).contains("# Actual"))
            @Expect(String.fromUtf8(File.readFrom(destination)).contains("Save"))
            @Expect(f.document().revision,before.revision);@Expect(f.document().encoded,before.encoded)
            @Expect(!exists(Path(destination+".tmp")))
            let defaultPath=f.root+"/workspace/TODO.md"
            @Expect(f.session.handle("/todo export").isOk());@Expect(!exists(Path(defaultPath)))
            @Expect(f.session.handle("/todo resource").isOk())
            @Expect(File.readFrom(defaultPath),File.readFrom(destination))
            @Expect(f.document().revision,before.revision);@Expect(f.document().encoded,before.encoded)
            @Expect(f.session.handle("/todo import").isOk())
            @Expect(f.session.handle("/todo resource").isOk())
            @Expect(f.session.handle("/todo commit").isOk())
            @Expect(f.document().encoded,before.encoded);f.noModel()
        }finally{f.close()}
    }
    @TestCase
    func uriExportApprovalCannotBorrowTheDocumentDecision(): Unit {
        let f=TodoNativeFrontendFixture("uri-export",mode:ApprovalMode.AlwaysAsk,resources:true)
        let uri=WorkspaceFrontendUri(content:"unchanged")
        try{
            @Expect(f.product.registerUriHandler("memory",uri).isOk())
            var response=f.session.replaceTodoPhases([ProductTodoPhase("Export",[ProductTodoItem("read this")])]).value().getOrThrow()
            let documentRead=response.approval.getOrThrow()
            @Expect(documentRead.toolName,HOST_CONTEXT_READ_TOOL);@Expect(uri.writeCount(),0)
            response=f.session.handle("/approve "+documentRead.operationId.value).value().getOrThrow()
            let documentWrite=response.approval.getOrThrow()
            @Expect(documentWrite.operationId.value!=documentRead.operationId.value)
            @Expect(documentWrite.toolName,"plugin."+productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace))+".todo");@Expect(uri.writeCount(),0)
            response=f.session.handle("/approve "+documentWrite.operationId.value).value().getOrThrow()
            @Expect(response.approval.isNone());@Expect(uri.writeCount(),0)
            let before=f.document()
            response=f.session.handle("/todo export memory://destination").value().getOrThrow()
            let exportRead=response.approval.getOrThrow()
            @Expect(exportRead.toolName,HOST_CONTEXT_READ_TOOL);@Expect(uri.writeCount(),0)
            response=f.session.handle("/approve "+exportRead.operationId.value).value().getOrThrow()
            let exportParent=response.approval.getOrThrow()
            @Expect(exportParent.operationId.value!=exportRead.operationId.value)
            @Expect(exportParent.toolName,"plugin."+productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace))+".todo");@Expect(uri.writeCount(),0)
            response=f.session.handle("/approve "+exportParent.operationId.value).value().getOrThrow()
            @Expect(response.approval.isNone());@Expect(uri.writeCount(),0)
            @Expect(uri.writeCount(),0)
            response=f.session.handle("/todo resource").value().getOrThrow()
            let request=response.approval.getOrThrow()
            @Expect(request.toolName,"write_resource");@Expect(!request.sessionApprovalAllowed)
            @Expect(uri.writeCount(),0);let _=f.session.handle("/reject "+request.operationId.value)
            @Expect(uri.writeCount(),0);@Expect(uri.text(),"unchanged")
            @Expect(f.document().revision,before.revision);@Expect(f.document().encoded,before.encoded)
            @Expect(f.rejectCount(),1);f.noModel()
        }finally{f.close()}
    }
    @TestCase
    func explicitColdMigrationPreservesLegacyBytesAndCannotReplaceExistingCurrentState(): Unit {
        let f=TodoNativeFrontendFixture("migration")
        try{
            let raw=encodeAgentValue(encodeTodoPhases([ProductTodoPhase("Cold",[ProductTodoItem("preserve")])]))
            f.database.execute("UPDATE thread_metadata SET todo_payload=? WHERE thread_id=?",[SqlParameter.Text(raw),SqlParameter.Text(f.session.id().value)])
            @Expect(f.session.todoPhases().value().getOrThrow().isEmpty())
            @Expect(f.session.handle("/todo migrate").isOk())
            @Expect(f.document().revision,1);@Expect(f.cold(),raw)
            @Expect(f.session.todoPhases().value().getOrThrow()[0].name,"Cold")
            let before=f.document()
            @Expect(f.session.handle("/todo migrate").isError())
            @Expect(f.document().revision,before.revision);@Expect(f.document().encoded,before.encoded);@Expect(f.cold(),raw)
            f.noModel()
        }finally{f.close()}
    }
    @TestCase
    func pendingColdMigrationRejectsChangedActualInputWithoutWritingCurrentDocument(): Unit {
        let f=TodoNativeFrontendFixture("migration-current",mode:ApprovalMode.AlwaysAsk)
        try{
            let original=encodeAgentValue(encodeTodoPhases([ProductTodoPhase("Cold original",[ProductTodoItem("preserve")])]))
            f.database.execute("UPDATE thread_metadata SET todo_payload=? WHERE thread_id=?",[SqlParameter.Text(original),SqlParameter.Text(f.session.id().value)])
            let response=f.session.handle("/todo migrate").value().getOrThrow()
            let approval=response.approval.getOrThrow()
            @Expect(f.document().revision,0);@Expect(f.cold(),original)
            let changed=encodeAgentValue(encodeTodoPhases([ProductTodoPhase("Actual changed",[ProductTodoItem("keep changed")])]))
            f.database.execute("UPDATE thread_metadata SET todo_payload=? WHERE thread_id=?",[SqlParameter.Text(changed),SqlParameter.Text(f.session.id().value)])
            @Expect(f.session.handle("/approve "+approval.operationId.value).isError())
            @Expect(f.document().revision,0);@Expect(f.cold(),changed)
            @Expect(f.session.cancel().isOk())
            @Expect(f.document().revision,0);@Expect(f.cold(),changed);f.noModel()
        }finally{f.close()}
    }
}
