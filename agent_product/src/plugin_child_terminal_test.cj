package agent_product

import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// This is the existing FixtureModelPort's nonretryable real model failure.
// It changes no fixture API or canonical source and must still leave an actual
// admitted child Run/Attempt whose failed terminal outcome can be observed.
func childTerminalFailurePrompt111(): String {
    "[plan-review approved original-fixture] FIXTURE-APPROVED-PLAN-EXECUTION-FAILURE"
}
func childTerminalSpecification111(fail: Bool): AgentValue {
    objectValue([ValueField("agent",textValue("scout")),
        ValueField("task",textValue(if(fail){childTerminalFailurePrompt111()}else{"actual sibling survives known child failure"}))])
}

@Test
class InstalledWorkflowKnownChildTerminalTests111 {
    @TestCase
    func actualFailedRunWithPersistedFinalizerReturnsBusinessErrorWithoutUnknownLaunch(): Unit {
        let f=WorkflowChildFixture111();let thread=SessionId("child-known-failure-111")
        try {
            let result=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(thread,f.capabilities(),
                ToolCall(thread.value+"-call","plugin."+f.namespace+".task",childTerminalSpecification111(true)),budget:f.budget()))
            try {
                @Expect(result.isError)
                let rows=result.output.field("results").getOrThrow().items
                @Expect(rows.size,1);@Expect(httpIntentText(rows[0],"status"),"failed")
                @Expect(rows[0].field("exitCode").getOrThrow().asNumberText(),"1")
                @Expect(httpIntentText(rows[0],"stderr").contains("fixture approved-plan execution failed"))
                @Expect(httpIntentText(rows[0],"output"),"")
                expectCanonicalReturnedReceipt(f.database,result)
            } finally { result.releasePayload() }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='failed'"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"),2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome IN ('unknown','rejected')"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"),0)
            let restored=ProductTaskPersistence(f.database).loadAll()
            @Expect(restored.size,1);@Expect(restored[0].subagents.size,1)
            @Expect(restored[0].subagents[0].status,"failed")
            @Expect(restored[0].subagents[0].pluginCompletionDone111)
            @Expect(restored[0].subagents[0].pluginAdmission111.isNone())
            @Expect(f.product.close().isOk())
        } finally { f.close() }
    }

    @TestCase
    func actualBatchKeepsOrderedFailedObservationAndSuccessfulSiblingWithExactWaitReceipts(): Unit {
        let f=WorkflowChildFixture111(waitService:true);let thread=SessionId("child-known-batch-failure-111")
        try {
            let result=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(thread,f.capabilities(),
                ToolCall(thread.value+"-call","plugin."+f.namespace+".task",objectValue([
                    ValueField("tasks",listValue([childTerminalSpecification111(true),childTerminalSpecification111(false)]))])),
                budget:childBatchBudget111()))
            try {
                @Expect(result.isError)
                let rows=result.output.field("results").getOrThrow().items
                @Expect(rows.size,2);@Expect(httpIntentText(rows[0],"status"),"failed")
                @Expect(rows[0].field("exitCode").getOrThrow().asNumberText(),"1")
                @Expect(httpIntentText(rows[0],"stderr").contains("fixture approved-plan execution failed"))
                @Expect(httpIntentText(rows[1],"status"),"completed")
                @Expect(rows[1].field("exitCode").getOrThrow().asNumberText(),"0")
                expectCanonicalReturnedReceipt(f.database,result)
            } finally { result.releasePayload() }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),3)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='failed'"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='completed'"),2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),4)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"),5)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome IN ('unknown','rejected')"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"),0)
            @Expect(f.product.close().isOk())
        } finally { f.close() }
    }

    @TestCase
    func actualFailedRunWithRefusedFinalizerPublicationKeepsUnknownAndBudgetCustody(): Unit {
        let f=WorkflowChildFixture111();let thread=SessionId("child-known-failure-journal-111")
        var installed=false
        try {
            f.database.execute("CREATE TRIGGER reject_known_child_finalizer_111 BEFORE UPDATE ON task_snapshots WHEN instr(NEW.payload,'\"pluginCompletionDone111\":true')>0 BEGIN SELECT RAISE(ABORT,'known failure finalizer publication refused'); END")
            installed=true
            let outcome=f.product.vnext.executeCanonicalTool(thread,f.capabilities(),
                ToolCall(thread.value+"-call","plugin."+f.namespace+".task",childTerminalSpecification111(true)),budget:f.budget())
            match(outcome){case Result.Err(_)=>()
                case Result.Ok(ToolInvocationResult.Completed(value))=>try{@Expect(value.isError)}finally{value.releasePayload()}
                case _=>@Expect(false)}
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='failed'"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts receipt JOIN operation_effect_records effect ON effect.operation_id=receipt.operation_id WHERE effect.tool_id='host.child.start' AND receipt.outcome='unknown'"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts receipt JOIN operation_effect_records effect ON effect.operation_id=receipt.operation_id WHERE effect.tool_id='host.child.start' AND receipt.outcome='completed'"),0)
            let children=f.product.allSubagents(thread)
            @Expect(children.size,1);@Expect(children[0].status,"recovery_required")
            let stored=ProductTaskPersistence(f.database).loadAll()
            @Expect(!stored[0].subagents[0].pluginCompletionDone111)
            @Expect(f.product.close().isError())
            f.database.execute("DROP TRIGGER reject_known_child_finalizer_111");installed=false
            @Expect(f.product.close().isOk())
            // Actual cleanup may settle the retained Task result, but it can
            // never rewrite the already unknown canonical service Receipt.
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts receipt JOIN operation_effect_records effect ON effect.operation_id=receipt.operation_id WHERE effect.tool_id='host.child.start' AND receipt.outcome='unknown'"),1)
        } finally {
            if(installed){f.database.execute("DROP TRIGGER reject_known_child_finalizer_111")}
            f.close()
        }
    }

    @TestCase
    func refusalBeforeActualRunAdmissionCannotUseTheKnownTerminalDataPath(): Unit {
        let f=WorkflowChildFixture111();let thread=SessionId("child-depth-refusal-111")
        try {
            let outcome=f.product.vnext.executeCanonicalTool(thread,f.capabilities(),f.call(thread.value),
                budget:ExecutionBudget(maxToolCalls:12,maxConcurrentTools:1,maxChildren:1,maxConcurrentChildren:1,maxDepth:0))
            match(outcome){case Result.Err(_)=>()
                case Result.Ok(ToolInvocationResult.Completed(value))=>try{@Expect(value.isError)}finally{value.releasePayload()}
                case _=>@Expect(false)}
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),0)
            @Expect(f.product.allSubagents(thread).size,0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts receipt JOIN operation_effect_records effect ON effect.operation_id=receipt.operation_id WHERE effect.tool_id='host.child.start' AND receipt.outcome='completed'"),0)
        } finally { f.close() }
    }
}
