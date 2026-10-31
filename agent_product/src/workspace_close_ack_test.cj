package agent_product

import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class WorkspaceCloseAcknowledgementTests {
    @TestCase
    func actualCancellationReceiptFailureCannotBecomeASecondCloseAcknowledgement(): Unit {
        let root=pluginContractTemp("workspace-close-fault")
        Directory.create(root+"/workspace",recursive:true)
        let product=workspacePluginOpen(root,ApprovalMode.AlwaysAsk)
        let database=SqliteDatabase(root+"/state/state.db")
        let uri=WorkspaceFrontendUri()
        try{
            let record=workspacePluginInstall(product,root);workspaceFrontendConfigure(root,record)
            product.registerUriHandler("memory",uri).value().getOrThrow()
            let parent=workspaceFrontendCall(product,"close-fault","write",objectValue([
                ValueField("path",textValue("memory://close-fault")),ValueField("content",textValue("must not write"))]))
            try{
                workspaceFrontendApprove(parent)
                let actual=parent.beginResource().value().getOrThrow()
                try{
                    let approval=actual.approval().getOrThrow()
                    @Expect(approval.toolName,"write_resource")
                    @Expect(uri.writeCount(),0);@Expect(parent.output().isOk());@Expect(actual.output().isError())
                    database.execute("CREATE TRIGGER workspace_close_fault BEFORE INSERT ON operation_receipts " +
                        "WHEN NEW.operation_id="+sqliteText(approval.operationId.value)+
                        " BEGIN SELECT RAISE(ABORT,'fixture cancellation receipt failure'); END")
                    let first=actual.close()
                    @Expect(first.isError())
                    let original=first.error().getOrThrow()
                    @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE operation_id="+
                        sqliteText(approval.operationId.value)),0)
                    database.execute("DROP TRIGGER workspace_close_fault")
                    let second=actual.close()
                    @Expect(second.isError());@Expect(refEq(second.error().getOrThrow(),original))
                    @Expect(actual.decide(approval.operationId.value,ApprovalDecision.Approve).isError())
                    @Expect(uri.writeCount(),0);@Expect(uri.text(),"first\nsecond\n")
                    @Expect(parent.output().isOk())
                    @Expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts"),0)
                    @Expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE operation_id="+
                        sqliteText(approval.operationId.value)+" AND kind='operation_execution_handoff'"),0)
                }finally{let _=actual.close()}
            }finally{let _=parent.close()}
        }finally{database.close();let _=product.close();remove(root,recursive:true)}
    }
    @TestCase
    func completedActualRootReleasesItsResultOnlyAfterAcknowledgedClose(): Unit {
        let root=pluginContractTemp("workspace-close-completed")
        Directory.create(root+"/workspace",recursive:true)
        File.writeTo(root+"/workspace/first.txt","real completed read\n".toArray())
        let product=workspacePluginOpen(root,ApprovalMode.Yolo)
        let database=SqliteDatabase(root+"/state/state.db")
        try{
            let record=workspacePluginInstall(product,root);workspaceFrontendConfigure(root,record)
            let actual=workspaceFrontendCall(product,"close-completed","read",objectValue([
                ValueField("path",textValue("first.txt:raw"))]))
            try{
                @Expect(actual.output().value().getOrThrow().field("content").getOrThrow().text,"real completed read\n")
                let before=database.scalarInt("SELECT COUNT(*) FROM operation_receipts")
                @Expect(actual.close().isOk());@Expect(actual.output().isError());@Expect(actual.close().isOk())
                @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),before)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts"),0)
                @Expect(String.fromUtf8(File.readFrom(root+"/workspace/first.txt")),"real completed read\n")
            }finally{let _=actual.close()}
        }finally{database.close();let _=product.close();remove(root,recursive:true)}
    }
    @TestCase
    func realPendingCancellationUsesCanonicalAcknowledgementInsteadOfItsExecutionErrorCode(): Unit {
        let root=pluginContractTemp("workspace-close-cancelled-ack")
        Directory.create(root+"/workspace",recursive:true)
        let product=workspacePluginOpen(root,ApprovalMode.AlwaysAsk)
        let database=SqliteDatabase(root+"/state/state.db")
        let uri=WorkspaceFrontendUri()
        try{
            let record=workspacePluginInstall(product,root);workspaceFrontendConfigure(root,record)
            product.registerUriHandler("memory",uri).value().getOrThrow()
            let parent=workspaceFrontendCall(product,"close-real-cancel","write",objectValue([
                ValueField("path",textValue("memory://cancel-ack")),ValueField("content",textValue("never write"))]))
            try{
                workspaceFrontendApprove(parent)
                let actual=parent.beginResource().value().getOrThrow()
                try{
                    let approval=actual.approval().getOrThrow()
                    @Expect(uri.writeCount(),0)
                    @Expect(actual.close().isOk());@Expect(actual.close().isOk())
                    @Expect(actual.output().isError());@Expect(actual.approval().isNone())
                    @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts r JOIN operation_effect_records e " +
                        "ON e.operation_id=r.operation_id WHERE r.operation_id="+sqliteText(approval.operationId.value)+
                        " AND r.id=e.reserved_receipt_id AND r.outcome='cancelled'"),1)
                    @Expect(database.scalarInt("SELECT COUNT(*) FROM operations o JOIN runs r ON r.id=o.run_id " +
                        "WHERE o.id="+sqliteText(approval.operationId.value)+" AND o.state='committed' AND r.state='cancelled'"),1)
                    @Expect(uri.writeCount(),0);@Expect(uri.text(),"first\nsecond\n")
                    @Expect(parent.output().isOk());@Expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts"),0)
                }finally{let _=actual.close()}
            }finally{let _=parent.close()}
        }finally{database.close();let _=product.close();remove(root,recursive:true)}
    }
    @TestCase
    func wrongReservedResultCannotReleaseTheOriginalResultUntilExactCanonicalProofReturns(): Unit {
        let root=pluginContractTemp("workspace-close-reserved-proof")
        Directory.create(root+"/workspace",recursive:true)
        File.writeTo(root+"/workspace/first.txt","retained real payload\n".toArray())
        let product=workspacePluginOpen(root,ApprovalMode.Yolo)
        let database=SqliteDatabase(root+"/state/state.db")
        try{
            let record=workspacePluginInstall(product,root);workspaceFrontendConfigure(root,record)
            let actual=workspaceFrontendCall(product,"close-reserved-proof","read",objectValue([
                ValueField("path",textValue("first.txt:raw"))]))
            try{
                let originalOutput=actual.output().value().getOrThrow()
                let rows=database.query("SELECT e.operation_id,e.reserved_result_item_id FROM operation_effect_records e " +
                    "JOIN operations o ON o.id=e.operation_id JOIN items i ON i.id=o.tool_call_item_id " +
                    "WHERE o.state='committed' AND i.kind='tool_call' AND e.operation_id NOT IN " +
                    "(SELECT operation_id FROM derived_operation_admissions) ORDER BY e.operation_id")
                @Expect(!rows.isEmpty())
                let operation=rows[0].required(0);let originalSlot=rows[0].required(1)
                let receipts=database.scalarInt("SELECT COUNT(*) FROM operation_receipts")
                database.execute("UPDATE operation_effect_records SET reserved_result_item_id=? WHERE operation_id=?",
                    [SqlParameter.Text("fixture-missing-reserved-result"),SqlParameter.Text(operation)])
                let first=actual.close();@Expect(first.isError());let originalError=first.error().getOrThrow()
                @Expect(canonicalAgentValue(actual.output().value().getOrThrow()),canonicalAgentValue(originalOutput))
                let second=actual.close();@Expect(second.isError());@Expect(refEq(second.error().getOrThrow(),originalError))
                // Restore the exact original actual bytes, never invent another
                // ToolResult or Receipt. The third close may now reclaim only.
                database.execute("UPDATE operation_effect_records SET reserved_result_item_id=? WHERE operation_id=?",
                    [SqlParameter.Text(originalSlot),SqlParameter.Text(operation)])
                @Expect(actual.close().isOk());@Expect(actual.output().isError());@Expect(actual.close().isOk())
                @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),receipts)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts"),0)
                @Expect(String.fromUtf8(File.readFrom(root+"/workspace/first.txt")),"retained real payload\n")
            }finally{let _=actual.close()}
        }finally{database.close();let _=product.close();remove(root,recursive:true)}
    }
    @TestCase
    func oversizedDurableMetadataCannotSpendUnpaidCopiesOrReleaseTheOriginalResult(): Unit {
        let root=pluginContractTemp("workspace-close-paid-metadata")
        Directory.create(root+"/workspace",recursive:true)
        File.writeTo(root+"/workspace/first.txt","bounded real payload\n".toArray())
        let product=workspacePluginOpen(root,ApprovalMode.Yolo)
        let database=SqliteDatabase(root+"/state/state.db")
        try{
            let record=workspacePluginInstall(product,root);workspaceFrontendConfigure(root,record)
            let actual=workspaceFrontendCall(product,"close-paid-metadata","read",objectValue([
                ValueField("path",textValue("first.txt:raw"))]))
            try{
                let originalOutput=actual.output().value().getOrThrow()
                let rows=database.query("SELECT r.id,r.detail FROM operation_receipts r " +
                    "JOIN operations o ON o.id=r.operation_id WHERE o.state='committed' " +
                    "AND o.id NOT IN (SELECT operation_id FROM derived_operation_admissions) ORDER BY r.id")
                @Expect(!rows.isEmpty());let receipt=rows[0].required(0);let detail=rows[0].required(1)
                let receipts=database.scalarInt("SELECT COUNT(*) FROM operation_receipts")
                // SQLite constructs the corrupt historical blob in place. The
                // cleanup's COUNT/UTF8 metadata must reject before raw SELECT
                // or codec DOM allocation; it cannot release the charged result.
                database.execute("UPDATE operation_receipts SET detail=CAST(zeroblob(16777217) AS TEXT) WHERE id=?",
                    [SqlParameter.Text(receipt)])
                let first=actual.close();@Expect(first.isError());let originalError=first.error().getOrThrow()
                @Expect(canonicalAgentValue(actual.output().value().getOrThrow()),canonicalAgentValue(originalOutput))
                let second=actual.close();@Expect(second.isError());@Expect(refEq(second.error().getOrThrow(),originalError))
                database.execute("UPDATE operation_receipts SET detail=? WHERE id=?",
                    [SqlParameter.Text(detail),SqlParameter.Text(receipt)])
                @Expect(actual.close().isOk());@Expect(actual.output().isError());@Expect(actual.close().isOk())
                @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),receipts)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts"),0)
                @Expect(String.fromUtf8(File.readFrom(root+"/workspace/first.txt")),"bounded real payload\n")
            }finally{let _=actual.close()}
        }finally{database.close();let _=product.close();remove(root,recursive:true)}
    }
}
