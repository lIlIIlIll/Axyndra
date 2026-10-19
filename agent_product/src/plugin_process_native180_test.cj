package agent_product

import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.fs.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// The original installed mixed Native package, real canonical Direct kernel
// and actual Store. No Source/receipt/history/process is inserted by a test.
func actualProcessSelection180(f:WorkflowChildFixture111):Unit{
    @Expect(f.product.setPluginEnabled(f.namespace,false).isOk())
    File.writeTo(f.root+"/settings/plugins/primitives.json",stringifyUnifiedJson(objectValue([
        ValueField("version",integerValue(1)),ValueField("plugins",listValue([objectValue([
            ValueField("namespace",textValue(f.namespace)),ValueField("package_digest",textValue(f.digest)),
            ValueField("tools",listValue([objectValue([ValueField("name",textValue("hub")),
                ValueField("profile",textValue("frozen-primitives-v1")),
                ValueField("services",listValue([textValue("process.service")])),
                ValueField("preparation_provider",textValue("prepare_child")),
                ValueField("invocation_capability",objectValue([ValueField("catalog",textValue("process.spawn")),
                    ValueField("services",objectValue([ValueField("process.service",textValue("process.spawn"))]))]))])]))])]))])).toArray())
    @Expect(f.product.setPluginEnabled(f.namespace,true).isOk())
}
func actualProcessCapabilities180(f:WorkflowChildFixture111):CapabilitySet{
    CapabilitySet(values:[Capability(CapabilityKind.ExtensionInvoke,resource:f.namespace),
        Capability(CapabilityKind.ProcessSpawn),Capability(CapabilityKind.WorkspaceRead)])
}
func actualProcessCall180(f:WorkflowChildFixture111,id:String,op:String,fields:Array<ValueField>):ToolCall{
    let value=objectValue(fields);value.put("op",textValue(op))
    ToolCall(id,"plugin."+f.namespace+".hub",value)
}
func actualProcessRun180(f:WorkflowChildFixture111,id:String,op:String,fields:Array<ValueField>):ToolResult{
    let value=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(SessionId("actual-process-owner-180"),
        actualProcessCapabilities180(f),actualProcessCall180(f,id,op,fields),budget:f.budget()))
    @Expect(!value.isError);@Expect(value.payloadLease.isSome());@Expect(httpIntentText(value.output,"op"),op)
    expectCanonicalReturnedReceipt(f.database,value)
    value
}
func actualProcessStartFields180(f:WorkflowChildFixture111,name:String):Array<ValueField>{
    [ValueField("name",textValue(name)),ValueField("application",textValue("/usr/bin/python3")),
        ValueField("args",listValue([textValue("-u"),textValue(f.root+"/actual-process180.py")])),
        ValueField("cwd",textValue(f.root)),ValueField("pty",boolValue(false)),ValueField("restart",textValue("no")),
        ValueField("ready",objectValue([ValueField("log",textValue("READY180")),ValueField("timeout",integerValue(5))]))]
}
func actualProcessScript180(f:WorkflowChildFixture111):Unit{
    File.writeTo(f.root+"/actual-process180.py",("import sys\nprint('READY180',flush=True)\n"+
        "value=bytearray()\nwhile True:\n c=sys.stdin.buffer.read(1)\n if not c: break\n"+
        " if c in (b'\\r',b'\\n'):\n  print('ECHO180:'+value.decode('utf-8'),flush=True); value.clear()\n"+
        " else: value.extend(c)\n").toArray())
}
func actualProcessExpectNoModel180(f:WorkflowChildFixture111):Unit{
    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),0)
    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='hub'"),0)
}

@Test
class InstalledWorkflowActualProcess180Tests {
    @TestCase
    func eightOriginalRoutesUseRealDerivedReceiptAndWholeProcessData180():Unit{
        let f=WorkflowChildFixture111()
        try{
            actualProcessSelection180(f);actualProcessScript180(f)
            let start=actualProcessRun180(f,"process-start-180","start",actualProcessStartFields180(f,"original180"))
            try{@Expect(start.output.field("daemon").getOrThrow().field("pid").getOrThrow().asInt64()>0)
                @Expect(!start.output.field("readyTimedOut").getOrThrow().asBool())}finally{start.releasePayload()}
            let list=actualProcessRun180(f,"process-ps-180","ps",[])
            try{@Expect(list.output.field("daemons").getOrThrow().items.size,1)}finally{list.releasePayload()}
            let describe=actualProcessRun180(f,"process-describe-180","describe",[ValueField("name",textValue("original180"))])
            try{@Expect(httpIntentText(describe.output.field("spec").getOrThrow(),"application"),"/usr/bin/python3")
                @Expect(describe.output.field("spec").getOrThrow().field("args").getOrThrow().items[1].text,f.root+"/actual-process180.py")}
            finally{describe.releasePayload()}
            let send=actualProcessRun180(f,"process-send-180","send",[ValueField("name",textValue("original180")),ValueField("text",textValue("whole 雪 180"))])
            try{@Expect(httpIntentText(send.output.field("daemon").getOrThrow(),"name"),"original180")}finally{send.releasePayload()}
            let wait=actualProcessRun180(f,"process-wait-180","wait",[ValueField("name",textValue("original180")),
                ValueField("for",textValue("log")),ValueField("pattern",textValue("ECHO180:whole 雪 180")),ValueField("timeout",integerValue(5))])
            try{@Expect(!wait.output.field("timedOut").getOrThrow().asBool())
                @Expect(wait.output.field("matched").getOrThrow().text.contains("ECHO180:whole 雪 180"))}finally{wait.releasePayload()}
            let logs=actualProcessRun180(f,"process-logs-180","logs",[ValueField("name",textValue("original180")),ValueField("grep",textValue("ECHO180"))])
            try{@Expect(logs.output.field("text").getOrThrow().text.contains("ECHO180:whole 雪 180"))}finally{logs.releasePayload()}
            let stop=actualProcessRun180(f,"process-stop-180","stop",[ValueField("name",textValue("original180")),ValueField("timeout",integerValue(1))])
            try{@Expect(stop.output.field("daemon").getOrThrow().field("pid").getOrThrow().unifiedKind,ValueKind.Null)}finally{stop.releasePayload()}
            let restart=actualProcessRun180(f,"process-restart-180","restart",[ValueField("name",textValue("original180")),
                ValueField("network",objectValue([ValueField("mode",textValue("denied"))]))])
            try{@Expect(restart.output.field("daemon").getOrThrow().field("pid").getOrThrow().asInt64()>0)}finally{restart.releasePayload()}
            let cleanup=actualProcessRun180(f,"process-cleanup-180","stop",[ValueField("name",textValue("original180")),ValueField("timeout",integerValue(1))])
            try{@Expect(cleanup.output.field("daemon").getOrThrow().field("pid").getOrThrow().unifiedKind,ValueKind.Null)}finally{cleanup.releasePayload()}
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='hub_process_service_reserved'"),9)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),9)
            actualProcessExpectNoModel180(f)
        }finally{f.close()}
    }
    @TestCase
    func actualSqlReservationRefusalCannotReachPhysicalProcessStart180():Unit{
        let f=WorkflowChildFixture111();let marker=f.root+"/forbidden-physical-start180"
        var trigger=false
        try{
            actualProcessSelection180(f)
            File.writeTo(f.root+"/actual-process180.py",("from pathlib import Path\nPath('"+marker+"').write_text('started')\n").toArray())
            f.database.execute("CREATE TRIGGER refuse_actual_process180 BEFORE INSERT ON audit_events WHEN NEW.kind='hub_process_service_reserved' BEGIN SELECT RAISE(ABORT,'actual process service reservation refused'); END")
            trigger=true
            let result=f.product.vnext.executeCanonicalTool(SessionId("actual-process-owner-180"),actualProcessCapabilities180(f),
                actualProcessCall180(f,"process-sql-refusal-180","start",actualProcessStartFields180(f,"refused180")),budget:f.budget())
            match(result){case Result.Err(_)=>();case Result.Ok(ToolInvocationResult.Completed(value))=>
                try{@Expect(value.isError)}finally{value.releasePayload()};case _=>@Expect(false)}
            @Expect(!exists(Path(marker)))
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='hub_process_service_reserved'"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts r JOIN operation_effect_records e ON e.operation_id=r.operation_id WHERE e.tool_id='host.child.start' AND r.outcome='completed'"),0)
            actualProcessExpectNoModel180(f)
        }finally{if(trigger){f.database.execute("DROP TRIGGER refuse_actual_process180")};f.close()}
    }
    @TestCase
    func mountedGenerationRevocationStopsActualOriginalIncarnationWithoutAnotherLaunch180():Unit{
        let f=WorkflowChildFixture111();var pid:Int64=0
        try{
            actualProcessSelection180(f);actualProcessScript180(f)
            let value=actualProcessRun180(f,"process-revocation-start-180","start",actualProcessStartFields180(f,"revoked180"))
            try{pid=value.output.field("daemon").getOrThrow().field("pid").getOrThrow().asInt64();@Expect(pid>0)}finally{value.releasePayload()}
            let admissions=f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='hub_process_service_reserved'")
            @Expect(f.product.setPluginEnabled(f.namespace,false).isOk())
            let until=MonoTime.now()+Duration.second*5
            while(exists(Path("/proc/"+pid.toString())) && MonoTime.now()<until){sleep(Duration.millisecond*5)}
            @Expect(!exists(Path("/proc/"+pid.toString())))
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='hub_process_service_reserved'"),admissions)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='hub_process_service_revoked'"),1)
            actualProcessExpectNoModel180(f)
        }finally{f.close()}
    }
}
