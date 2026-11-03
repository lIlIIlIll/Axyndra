package agent_product

import agent_domain.*
import agent_store.*
import agent_host_runtime.*
import tool_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func programPreviewCode(): String {
    let proposal=objectValue([ValueField("schema",textValue(HOST_FILE_APPLICATION_PROPOSAL_SCHEMA)),
        ValueField("operations",listValue([objectValue([ValueField("kind",textValue("replace")),
            ValueField("path",textValue("first.txt")),ValueField("expected_content",textValue("before\n")),
            ValueField("content",textValue("after\n"))])]))])
    return "const a = await tools.read({\"path\":\"first.txt\"}); return "+
        encodeAgentValue(objectValue([ValueField("application_plan",proposal)]))+";"
}

@Test
class PluginProgramFilePlanPreviewTests {
    @TestCase
    func actualOptedInPreviewIsFourthChargedChildAndDoesNotApplyWrites(): Unit {
        let f=ProgramDelegationFixture(filePlanProposals:Some(true))
        try{
            let budget=ExecutionBudget(maxToolCalls:4,maxConcurrentTools:1)
            let result=f.completed(f.direct("program-plan-opted-in",f.input(code:programPreviewCode()),budget))
            try{
                @Expect(!result.isError);@Expect(result.receiptId!="")
                let plan=result.output.field("value").getOrThrow().field("application_plan").getOrThrow()
                @Expect(plan.field("plan_ref").getOrThrow().text.startsWith(PRODUCT_ARTIFACT_PREFIX))
                @Expect(plan.field("plan_digest").getOrThrow().text!="")
                @Expect(budget.snapshot().toolCalls,4);@Expect(budget.snapshot().activeTools,0)
                @Expect(f.children("program-plan-opted-in"),3)
                let rows=f.database.query("SELECT a.depth,a.parent_operation_id,a.root_operation_id,p.outcome,e.tool_id,p.id " +
                    "FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id JOIN operation_effect_records e ON e.operation_id=o.id " +
                    "JOIN runs r ON r.id=o.run_id JOIN operation_receipts p ON p.operation_id=o.id " +
                    "WHERE r.thread_id='program-plan-opted-in' AND e.tool_id='host.file.plan.propose'")
                @Expect(rows.size,1);@Expect(rows[0].required(0),"1")
                @Expect(rows[0].required(1),rows[0].required(2));@Expect(rows[0].required(3),"completed")
                @Expect(rows[0].required(5)!=result.receiptId)
                let identity=f.database.query("SELECT a.operation_id,a.parent_operation_id,o.run_id FROM derived_operation_admissions a " +
                    "JOIN operations o ON o.id=a.operation_id JOIN operation_effect_records e ON e.operation_id=o.id " +
                    "JOIN runs r ON r.id=o.run_id WHERE r.thread_id='program-plan-opted-in' AND e.tool_id='host.file.plan.propose'")[0]
                let store=DurableOperationStore(f.database)
                let parent=store.loadPlan(OperationId(identity.required(1)),RunId(identity.required(2))).value().getOrThrow()
                let child=store.loadPlan(OperationId(identity.required(0)),RunId(identity.required(2))).value().getOrThrow()
                @Expect(readonlyDelegationFilePlanProposalAllowed(parent,child))
                child.canonicalArguments.put("generation",textValue("18446744073709551615"))
                @Expect(!readonlyDelegationFilePlanProposalAllowed(parent,child))
                @Expect(String.fromUtf8(File.readFrom(f.root+"/workspace/first.txt")),"before\n")
            }finally{result.releasePayload()}
        }finally{f.close()}
    }

    @TestCase
    func DefaultAndExplicitFalseRefuseProposalWithoutMintingPreviewChild(): Unit {
        let choices:Array<?Bool>=[None,Some(false)]
        for(enabled in choices){
            let f=ProgramDelegationFixture(filePlanProposals:enabled)
            try{
                let result=f.completed(f.direct("program-plan-default",f.input(code:programPreviewCode()),
                    ExecutionBudget(maxToolCalls:4,maxConcurrentTools:1)))
                try{@Expect(result.isError)
                    @Expect(f.count("program-plan-default","SELECT COUNT(*) FROM operations o JOIN operation_effect_records e ON e.operation_id=o.id JOIN runs r ON r.id=o.run_id WHERE r.thread_id=? AND e.tool_id='host.file.plan.propose'"),0)
                    @Expect(String.fromUtf8(File.readFrom(f.root+"/workspace/first.txt")),"before\n")
                }finally{result.releasePayload()}
            }finally{f.close()}}
    }

    @TestCase
    func MalformedOperatorFlagAndForgedInputFlagCannotBecomeHostAuthority(): Unit {
        let f=ProgramDelegationFixture()
        try{
            let path=f.root+"/settings/plugins/services.json"
            let original=String.fromUtf8(File.readFrom(path))
            let malformed=parseUnifiedJson(original)
            malformed.field("plugins").getOrThrow().items[1].field("tool_delegations").getOrThrow().items[0]
                .put("file_plan_proposals",textValue("true"))
            File.writeTo(path,stringifyUnifiedJson(malformed).toArray())
            @Expect(!hostValidReadonlyDelegationGrants(malformed.field("plugins").getOrThrow().items[1].field("tool_delegations").getOrThrow()))
            let rejected=f.direct("program-plan-malformed",f.input(code:programPreviewCode()),ExecutionBudget(maxToolCalls:4,maxConcurrentTools:1))
            @Expect(match(rejected){case Result.Err(_)=>true;case Result.Ok(ToolInvocationResult.Completed(value))=>try{value.isError}finally{value.releasePayload()};case Result.Ok(ToolInvocationResult.Denied(_))=>true;case _=>false})
            @Expect(f.children("program-plan-malformed"),0)
            File.writeTo(path,original.toArray())
            let forged=f.input(code:programPreviewCode());forged.put("host_plan",objectValue([ValueField("file_plan_proposals",boolValue(true))]))
            let result=f.completed(f.direct("program-plan-forged",forged,ExecutionBudget(maxToolCalls:4,maxConcurrentTools:1)))
            try{@Expect(result.isError);@Expect(f.children("program-plan-forged"),0)}finally{result.releasePayload()}
        }finally{f.close()}
    }

    @TestCase
    func RevokedPreviewFlagBeforeOriginalApprovalDispatchesNoChild(): Unit {
        let f=ProgramDelegationFixture(mode:ApprovalMode.Write,filePlanProposals:Some(true))
        try{
            let session=f.product.applicationSession(sessionId:Some(SessionId("program-plan-revoked")))
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("program-plan-revoked",f.name,f.input(code:programPreviewCode()))
            @Expect(session.submit("Review this exact program preview.").isOk())
            let approval=session.approval().getOrThrow();@Expect(f.children("program-plan-revoked"),0)
            let path=f.root+"/settings/plugins/services.json";let changed=parseUnifiedJson(String.fromUtf8(File.readFrom(path)))
            changed.field("plugins").getOrThrow().items[1].field("tool_delegations").getOrThrow().items[0]
                .put("file_plan_proposals",boolValue(false))
            File.writeTo(path,stringifyUnifiedJson(changed).toArray())
            let outcome=session.decide(approval.operationId.value,ApprovalDecision.Approve)
            @Expect(outcome.isError() || session.approval().isNone())
            @Expect(f.children("program-plan-revoked"),0)
            @Expect(String.fromUtf8(File.readFrom(f.root+"/workspace/first.txt")),"before\n")
        }finally{f.close()}
    }

    @TestCase
    func ActualFourthPreviewCannotBorrowTheThreeCallParentBudget(): Unit {
        let f=ProgramDelegationFixture(filePlanProposals:Some(true))
        try{
            let budget=ExecutionBudget(maxToolCalls:3,maxConcurrentTools:1)
            let result=f.completed(f.direct("program-plan-budget",f.input(code:programPreviewCode()),budget))
            try{@Expect(result.isError);@Expect(budget.snapshot().toolCalls,3)
                @Expect(f.count("program-plan-budget","SELECT COUNT(*) FROM operations o JOIN operation_effect_records e ON e.operation_id=o.id JOIN runs r ON r.id=o.run_id JOIN operation_receipts p ON p.operation_id=o.id WHERE r.thread_id=? AND e.tool_id='host.file.plan.propose' AND p.outcome='completed'"),0)
                @Expect(String.fromUtf8(File.readFrom(f.root+"/workspace/first.txt")),"before\n")
            }finally{result.releasePayload()}
        }finally{f.close()}
    }
}
