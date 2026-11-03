package agent_product

import agent_plugin_registry

import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.fs.*
import std.convert.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// A real trusted URI owner. The package sees only its reference; counters prove
// that neither prepare nor the read-only worker invokes the handler.
class WorkspaceFrontendUri <: InternalUriHandler {
    private let lock=Mutex()
    private var content="first\nsecond\n"
    private var reads:Int64=0
    private var writes:Int64=0
    init(content!:String="first\nsecond\n"){this.content=content}
    public func read(context: ToolInvocationContext,url: String): Result<InternalUriResource> {
        match(context.cancellation.check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        lock.lock();try{reads++;Result.Ok(InternalUriResource(url,content,notes:["actual owner read"]))}finally{lock.unlock()}
    }
    public func write(context: ToolInvocationContext,url: String,value: String): Result<Unit> {
        match(context.cancellation.check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        lock.lock();try{writes++;content=value;Result.Ok(())}finally{lock.unlock()}
    }
    public func writable(): Bool { true }
    func readCount(): Int64 {lock.lock();try{reads}finally{lock.unlock()}}
    func writeCount(): Int64 {lock.lock();try{writes}finally{lock.unlock()}}
    func text(): String {lock.lock();try{content}finally{lock.unlock()}}
}

func workspaceFrontendConfigure(root: String,record: ProductPluginRecord): Unit {
    workspaceReadViewConfigure(root,record,["read","grep","glob"],parameterReferences:["write"])
    File.writeTo(root+"/settings/plugins/workspace-tools.json",stringifyUnifiedJson(objectValue([
        ValueField("schema",textValue("axyndra.workspace-tools/v1")),ValueField("namespace",textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))),
        ValueField("package_digest",textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest))))])).toArray())
}
func workspaceFrontendCall(product: ProductRuntime,thread: String,name: String,args: AgentValue): ProductWorkspaceInvocation {
    product.invokeWorkspaceTool(SessionId(thread),name,args).value().getOrThrow()
}
func workspaceFrontendApprove(invocation: ProductWorkspaceInvocation): Unit {
    var count:Int64=0
    while(invocation.approval().isSome()){
        if(count>=2){throw IllegalStateException("bounded actual Root reviews exceeded")};count++
        let approval=invocation.approval().getOrThrow()
        if(approval.operationId.value==""){throw IllegalStateException("actual Root operation is missing")}
        invocation.decide(approval.operationId.value,ApprovalDecision.Approve).value().getOrThrow()
    }
}
func workspaceFrontendRoots(database: SqliteDatabase,thread: String): Int64 {
    let rows=database.query("SELECT COUNT(*) FROM operation_receipts p JOIN operations o ON o.id=p.operation_id " +
        "JOIN runs r ON r.id=o.run_id WHERE r.thread_id=? AND p.outcome='completed' AND " +
        "NOT EXISTS(SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=o.id)",[SqlParameter.Text(thread)])
    Int64.parse(rows[0].required(0))
}

@Test
class WorkspaceFrontendTests {
    @TestCase
    func absentSelectionAndDisabledActualPackageFailBeforeAnyNewRoot(): Unit {
        let root=pluginContractTemp("workspace-frontend-unprovided");Directory.create(root+"/workspace",recursive:true)
        let product=workspacePluginOpen(root,ApprovalMode.Yolo);let database=SqliteDatabase(root+"/state/state.db")
        try{
            @Expect(product.invokeWorkspaceTool(SessionId("unselected"),"read",objectValue([ValueField("path",textValue("first.txt"))])).isError())
            @Expect(database.scalarInt("SELECT COUNT(*) FROM runs"),0)
            let record=workspacePluginInstall(product,root);workspaceFrontendConfigure(root,record)
            let _=product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)),false,PluginInstallScope.Workspace)
            @Expect(product.invokeWorkspaceTool(SessionId("disabled-selection"),"write",objectValue([
                ValueField("path",textValue("new.txt")),ValueField("content",textValue("forbidden"))])).isError())
            @Expect(database.scalarInt("SELECT COUNT(*) FROM runs"),0);@Expect(!exists(Path(root+"/workspace/new.txt")))
        }finally{database.close();product.close();remove(root,recursive:true)}
    }
    @TestCase
    func actualNativeUriProposalNeedsASeparateRootAndCannotBeChangedThroughItsDto(): Unit {
        let root=pluginContractTemp("workspace-frontend-uri");Directory.create(root+"/workspace",recursive:true)
        let product=workspacePluginOpen(root,ApprovalMode.Yolo);let database=SqliteDatabase(root+"/state/state.db")
        let uri=WorkspaceFrontendUri()
        try{
            let record=workspacePluginInstall(product,root);workspaceFrontendConfigure(root,record)
            @Expect(product.registerUriHandler("memory",uri).isOk())
            let read=workspaceFrontendCall(product,"uri-read","read",objectValue([ValueField("path",textValue("memory://actual"))]))
            try{
                @Expect(uri.readCount(),0);@Expect(uri.writeCount(),0);@Expect(workspaceFrontendRoots(database,"uri-read"),1)
                let copy=read.output().value().getOrThrow()
                copy.put("resource_request",objectValue([ValueField("tool",textValue("write_resource"))]))
                let actual=read.beginResource().value().getOrThrow()
                try{
                    @Expect(actual.output().value().getOrThrow().field("content").getOrThrow().text,"first\nsecond\n")
                    @Expect(uri.readCount(),1);@Expect(uri.writeCount(),0);@Expect(workspaceFrontendRoots(database,"uri-read"),2)
                    @Expect(read.beginResource().isError())
                }finally{actual.close()}
            }finally{read.close()}
            let write=workspaceFrontendCall(product,"uri-write","write",objectValue([
                ValueField("path",textValue("memory://actual")),ValueField("content",textValue("雪 changed\n"))]))
            try{
                @Expect(uri.writeCount(),0);@Expect(!write.output().value().getOrThrow().field("applied").getOrThrow().asBool())
                let actual=write.beginResource().value().getOrThrow()
                try{
                    @Expect(actual.output().value().getOrThrow().field("applied").getOrThrow().asBool())
                    @Expect(uri.writeCount(),1);@Expect(uri.text(),"雪 changed\n");@Expect(workspaceFrontendRoots(database,"uri-write"),2)
                }finally{actual.close()}
            }finally{write.close()}
            let unknown=workspaceFrontendCall(product,"uri-missing","read",objectValue([ValueField("path",textValue("missing://actual"))]))
            try{@Expect(unknown.beginResource().isError());@Expect(uri.readCount(),1);@Expect(uri.writeCount(),1)}finally{unknown.close()}
        }finally{database.close();product.close();remove(root,recursive:true)}
    }
    @TestCase
    func newUriWriteRootExposesItsOwnApprovalAndRejectLeavesActualOwnerUntouched(): Unit {
        let root=pluginContractTemp("workspace-frontend-uri-approval");Directory.create(root+"/workspace",recursive:true)
        let product=workspacePluginOpen(root,ApprovalMode.AlwaysAsk);let database=SqliteDatabase(root+"/state/state.db");let uri=WorkspaceFrontendUri()
        try{
            let record=workspacePluginInstall(product,root);workspaceFrontendConfigure(root,record);product.registerUriHandler("memory",uri).value().getOrThrow()
            let proposal=workspaceFrontendCall(product,"uri-approve","write",objectValue([
                ValueField("path",textValue("memory://actual")),ValueField("content",textValue("not yet"))]))
            try{
                workspaceFrontendApprove(proposal);@Expect(uri.writeCount(),0)
                let actual=proposal.beginResource().value().getOrThrow()
                try{
                    let approval=actual.approval().getOrThrow()
                    @Expect(approval.toolName,"write_resource");@Expect(approval.capability.kind,CapabilityKind.WorkspaceWrite)
                    @Expect(!approval.sessionApprovalAllowed);@Expect(uri.writeCount(),0);@Expect(actual.output().isError())
                    @Expect(actual.decide(approval.operationId.value,ApprovalDecision.Reject).isError())
                    @Expect(uri.writeCount(),0);@Expect(uri.text(),"first\nsecond\n")
                    @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts p JOIN operations o ON o.id=p.operation_id " +
                        "JOIN runs r ON r.id=o.run_id WHERE r.thread_id='uri-approve' AND p.outcome='rejected'"),1)
                }finally{actual.close()}
            }finally{proposal.close()}
        }finally{database.close();product.close();remove(root,recursive:true)}
    }
    @TestCase
    func native32768ByteFrozenWriteAppliesAtomicallyThroughAnIndependentRoot(): Unit {
        let root=pluginContractTemp("workspace-frontend-full-write");Directory.create(root+"/workspace",recursive:true)
        let product=workspacePluginOpen(root,ApprovalMode.Yolo);let database=SqliteDatabase(root+"/state/state.db")
        // Every byte needs six JSON bytes: input is a frozen view file, not argv.
        let content=String.fromUtf8(Array<Byte>(32768,repeat:1))
        try{
            let record=workspacePluginInstall(product,root);workspaceFrontendConfigure(root,record)
            let proposal=workspaceFrontendCall(product,"full-write","write",objectValue([
                ValueField("path",textValue("new.txt")),ValueField("content",textValue(content))]))
            try{
                @Expect(!exists(Path(root+"/workspace/new.txt")));@Expect(workspaceFrontendRoots(database,"full-write"),1)
                let actual=proposal.beginResource().value().getOrThrow()
                try{
                    @Expect(actual.output().isOk());@Expect(String.fromUtf8(File.readFrom(root+"/workspace/new.txt")),content)
                    @Expect(workspaceFrontendRoots(database,"full-write"),2)
                    @Expect(database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id " +
                        "JOIN runs r ON r.id=o.run_id WHERE r.thread_id='full-write'"),2)
                }finally{actual.close()}
            }finally{proposal.close()}
            @Expect(product.invokeWorkspaceTool(SessionId("oversize-write"),"write",objectValue([
                ValueField("path",textValue("oversize.txt")),ValueField("content",textValue(content+"x"))])).isError())
            @Expect(!exists(Path(root+"/workspace/oversize.txt")))
        }finally{database.close();product.close();remove(root,recursive:true)}
    }
    @TestCase
    func dual32768ByteReplacementRetainsActualHashCasAndConflictCannotWrite(): Unit {
        let root=pluginContractTemp("workspace-frontend-full-replace");Directory.create(root+"/workspace",recursive:true)
        let before=String.fromUtf8(Array<Byte>(32768,repeat:1));let after=String.fromUtf8(Array<Byte>(32768,repeat:2))
        File.writeTo(root+"/workspace/replace.txt",before.toArray())
        let product=workspacePluginOpen(root,ApprovalMode.Yolo);let database=SqliteDatabase(root+"/state/state.db")
        try{
            let record=workspacePluginInstall(product,root);workspaceFrontendConfigure(root,record)
            let proposal=workspaceFrontendCall(product,"full-replace","write",objectValue([
                ValueField("path",textValue("replace.txt")),ValueField("content",textValue(after))]))
            try{
                @Expect(String.fromUtf8(File.readFrom(root+"/workspace/replace.txt")),before)
                let actual=proposal.beginResource().value().getOrThrow()
                try{@Expect(actual.output().isOk());@Expect(String.fromUtf8(File.readFrom(root+"/workspace/replace.txt")),after)}finally{actual.close()}
                @Expect(workspaceFrontendRoots(database,"full-replace"),2)
            }finally{proposal.close()}
            let conflict=workspaceFrontendCall(product,"full-replace-conflict","write",objectValue([
                ValueField("path",textValue("replace.txt")),ValueField("content",textValue(before))]))
            try{
                File.writeTo(root+"/workspace/replace.txt","concurrent actual bytes".toArray())
                @Expect(conflict.beginResource().isError())
                @Expect(String.fromUtf8(File.readFrom(root+"/workspace/replace.txt")),"concurrent actual bytes")
                @Expect(workspaceFrontendRoots(database,"full-replace-conflict"),1)
            }finally{conflict.close()}
        }finally{database.close();product.close();remove(root,recursive:true)}
    }
    @TestCase
    func actualPlanArtifactReadAndExportUseExistingOwnerAndDistinctCanonicalReceipts(): Unit {
        let root=pluginContractTemp("workspace-frontend-artifact");Directory.create(root+"/workspace",recursive:true)
        let product=workspacePluginOpen(root,ApprovalMode.Yolo);let database=SqliteDatabase(root+"/state/state.db")
        try{
            let record=workspacePluginInstall(product,root);workspaceFrontendConfigure(root,record)
            let source=workspaceFrontendCall(product,"artifact-source","write",objectValue([
                ValueField("path",textValue("unapplied.txt")),ValueField("content",textValue("real immutable plan"))]))
            try{
                let reference=source.output().value().getOrThrow().field("application_plan").getOrThrow().field("plan_ref").getOrThrow().text
                let read=workspaceFrontendCall(product,"artifact-read","read",objectValue([ValueField("path",textValue(reference))]))
                let text=try{
                    let actual=read.beginResource().value().getOrThrow()
                    try{
                        let output=actual.output().value().getOrThrow();@Expect(output.field("artifact_ref").getOrThrow().text,reference)
                        @Expect(output.field("immutable").getOrThrow().asBool());@Expect(workspaceFrontendRoots(database,"artifact-read"),2)
                        output.field("content").getOrThrow().text
                    }finally{actual.close()}
                }finally{read.close()}
                @Expect(parseUnifiedJson(text).field("schema").getOrThrow().text,"axyndra.file-application-plan/v2")
                let export=workspaceFrontendCall(product,"artifact-export","read",objectValue([
                    ValueField("path",textValue(reference)),ValueField("destination",textValue("exported.json"))]))
                try{
                    @Expect(!exists(Path(root+"/workspace/exported.json")))
                    let actual=export.beginResource().value().getOrThrow()
                    try{
                        @Expect(actual.output().isOk());@Expect(String.fromUtf8(File.readFrom(root+"/workspace/exported.json")),text)
                        @Expect(workspaceFrontendRoots(database,"artifact-export"),2)
                    }finally{actual.close()}
                }finally{export.close()}
                @Expect(!exists(Path(root+"/workspace/unapplied.txt")))
                let escaped=product.invokeWorkspaceTool(SessionId("artifact-escape"),"read",objectValue([
                    ValueField("path",textValue(reference)),ValueField("destination",textValue("../outside.json"))]))
                @Expect(escaped.isError());@Expect(!exists(Path(root+"/outside.json")))
            }finally{source.close()}
        }finally{database.close();product.close();remove(root,recursive:true)}
    }

    @TestCase
    func resourcePageCopyKeepsOriginalOneMiBByteCeilingForControlCharacters(): Unit {
        let root=pluginContractTemp("workspace-resource-page-copy");Directory.create(root+"/workspace",recursive:true)
        let product=workspacePluginOpen(root,ApprovalMode.Yolo);let database=SqliteDatabase(root+"/state/state.db")
        let bytes=Array<Byte>(1048576,repeat:1u8);let uri=WorkspaceFrontendUri(content:String.fromUtf8(bytes))
        let tooLarge=WorkspaceFrontendUri(content:String.fromUtf8(Array<Byte>(1048577,repeat:1u8)))
        try{
            let record=workspacePluginInstall(product,root);workspaceFrontendConfigure(root,record)
            product.registerUriHandler("page",uri).value().getOrThrow();product.registerUriHandler("oversize",tooLarge).value().getOrThrow()
            let proposal=workspaceFrontendCall(product,"resource-page","read",objectValue([ValueField("path",textValue("page://actual"))]))
            try{
                @Expect(uri.readCount(),0)
                let actual=proposal.beginResource().value().getOrThrow()
                try{
                    let page=actual.output().value().getOrThrow()
                    @Expect(page.field("content").getOrThrow().text.toArray(),bytes)
                    @Expect(page.field("returned_bytes").getOrThrow().asNumberText(),"1048576")
                    @Expect(uri.readCount(),1);@Expect(workspaceFrontendRoots(database,"resource-page"),2)
                }finally{actual.close().value().getOrThrow()}
            }finally{proposal.close().value().getOrThrow()}
            let oversized=workspaceFrontendCall(product,"resource-page-oversize","read",objectValue([ValueField("path",textValue("oversize://actual"))]))
            try{
                @Expect(tooLarge.readCount(),0);@Expect(oversized.beginResource().isError())
                @Expect(tooLarge.readCount(),1);@Expect(uri.writeCount(),0);@Expect(tooLarge.writeCount(),0)
                @Expect(workspaceFrontendRoots(database,"resource-page-oversize"),1)
            }finally{oversized.close().value().getOrThrow()}
        }finally{database.close();product.close();remove(root,recursive:true)}
    }
}
