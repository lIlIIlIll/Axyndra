package agent_product

import agent_core.*
import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func yieldWriterMount150(f: WorkflowChildFixture111): Unit {
    @Expect(f.product.setPluginEnabled(f.namespace,false).isOk())
    let tools=listValue([
        objectValue([ValueField("name",textValue("task")),ValueField("profile",textValue("frozen-primitives-v1")),
            ValueField("services",listValue([textValue("child.start")])),ValueField("preparation_provider",textValue("prepare_child"))]),
        objectValue([ValueField("name",textValue("yield")),ValueField("profile",textValue("frozen-primitives-v1")),
            ValueField("services",listValue([textValue("child.result.write")])),ValueField("preparation_provider",textValue("prepare_child")),
            ValueField("invocation_capability",textValue("workspace.read"))])])
    File.writeTo(f.root+"/settings/plugins/primitives.json",encodeAgentValue(objectValue([
        ValueField("version",integerValue(1)),ValueField("plugins",listValue([objectValue([
            ValueField("namespace",textValue(f.namespace)),ValueField("package_digest",textValue(f.digest)),
            ValueField("tools",tools)])]))])).toArray())
    @Expect(f.product.setPluginEnabled(f.namespace,true).isOk())
}

@Test
class InstalledNativeYieldWriter150Tests {
    @TestCase
    func actualNativeYieldWritesExistingCanonicalChildAndPreservesReceipt150(): Unit {
        let f=WorkflowChildFixture111()
        try {
            yieldWriterMount150(f)
            let data=objectValue([ValueField("answer",textValue("reviewed 雪\u{0000} whole"))])
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("actual-native-yield-call150",
                "plugin."+f.namespace+".yield",objectValue([ValueField("result",objectValue([ValueField("data",data)]))]))
            let result=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(SessionId("native-yield-child150"),
                f.capabilities(),f.call("native-yield-child150"),budget:f.budget()))
            try {
                @Expect(!result.isError)
                let rows=result.output.field("results").getOrThrow().items
                @Expect(rows.size,1)
                @Expect(rows[0].field("exitCode").getOrThrow().asNumberText(),"0")
                @Expect(httpIntentText(rows[0],"status"),"completed")
                let output=parseUnifiedJson(httpIntentText(rows[0],"output"))
                @Expect(canonicalAgentValue(output),canonicalAgentValue(data))
                expectCanonicalReturnedReceipt(f.database,result)
            } finally {result.releasePayload()}
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts")>=2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='plugin."+f.namespace+".yield'"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"),0)
            f.database.transaction { tx: SqliteTransaction =>
                let plans=tx.query("SELECT o.normalized_plan FROM operations o JOIN operation_effect_records e ON e.operation_id=o.id WHERE e.tool_id=?",
                    [SqlParameter.Text("plugin."+f.namespace+".yield")])
                @Expect(plans.size,1)
                let plan=decodeOperationPlan(plans[0].required(0))
                @Expect(pluginPrimitivePlanService111(plan),"child.result.write")
                @Expect(plan.requiredCapabilities.size,1)
                @Expect(plan.requiredCapabilities[0].kind,CapabilityKind.WorkspaceRead)
                @Expect(plan.requiredCapabilities[0].resource,"")
            }
        } finally {f.close()}
    }
    @TestCase
    func unavailableAndMissingOriginalCapabilityCannotInventDelegatedChild150(): Unit {
        let f=WorkflowChildFixture111()
        try {
            yieldWriterMount150(f)
            let call=ToolCall("outside-native-yield150","plugin."+f.namespace+".yield",
                objectValue([ValueField("result",objectValue([ValueField("data",textValue("outside"))]))]))
            let result=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(SessionId("outside-yield150"),
                CapabilitySet(values:[Capability(CapabilityKind.WorkspaceRead)]),call,budget:f.budget()))
            try {
                @Expect(result.isError)
                @Expect(httpIntentText(result.output,"error"),"yield is only available inside a delegated task")
                expectCanonicalReturnedReceipt(f.database,result)
            } finally {result.releasePayload()}
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),0)
            let before=f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions")
            match(f.product.vnext.executeCanonicalTool(SessionId("no-yield-cap150"),CapabilitySet(values:[]),call,budget:f.budget())) {
                case Result.Err(_)=>()
                case Result.Ok(ToolInvocationResult.Denied(_))=>()
                case Result.Ok(ToolInvocationResult.Completed(value))=>try{@Expect(value.isError)}finally{value.releasePayload()}
                case _=>@Expect(false)
            }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),before)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"),0)
        } finally {f.close()}
    }
}


@Test
class NativeYieldDefaultRetirement150Tests {
    @TestCase
    func realSelectedCatalogHasOnlyNativeYieldAndDisabledPackageHasNoFallback150(): Unit {
        let f=WorkflowChildFixture111()
        try {
            yieldWriterMount150(f)
            @Expect(!f.product.tools().any({ value => value.name=="yield" }))
            @Expect(f.product.tools().any({ value => value.name=="plugin."+f.namespace+".yield" }))
            let before=f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='host.child.result.write'")
            @Expect(f.product.setPluginEnabled(f.namespace,false).isOk())
            @Expect(!f.product.tools().any({ value => value.name=="yield" || value.name=="plugin."+f.namespace+".yield" }))
            let call=ToolCall("disabled-yield150","plugin."+f.namespace+".yield",
                objectValue([ValueField("result",objectValue([ValueField("data",textValue("cannot fallback"))]))]))
            match(f.product.vnext.executeCanonicalTool(SessionId("disabled-yield150"),f.capabilities(),call,budget:f.budget())){
                case Result.Err(_)=>()
                case Result.Ok(ToolInvocationResult.Denied(_))=>()
                case Result.Ok(ToolInvocationResult.Completed(value))=>try{@Expect(value.isError)}finally{value.releasePayload()}
                case _=>@Expect(false)
            }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='host.child.result.write'"),before)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"),0)
        } finally {f.close()}
    }
    @TestCase
    func actualUnselectedPackageCannotFallBackToRetiredHostYield150(): Unit {
        let f=WorkflowChildFixture111(selected:false)
        try {
            @Expect(!f.product.tools().any({ value => value.name=="yield" }))
            let before=f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='host.child.result.write'")
            let call=ToolCall("unselected-yield150","plugin."+f.namespace+".yield",
                objectValue([ValueField("result",objectValue([ValueField("data",textValue("no operator selection"))]))]))
            match(f.product.vnext.executeCanonicalTool(SessionId("unselected-yield150"),f.capabilities(),call,budget:f.budget())){
                case Result.Err(_)=>()
                case Result.Ok(ToolInvocationResult.Denied(_))=>()
                case Result.Ok(ToolInvocationResult.Completed(value))=>try{@Expect(value.isError)}finally{value.releasePayload()}
                case _=>@Expect(false)
            }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='host.child.result.write'"),before)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"),0)
        } finally {f.close()}
    }
}
