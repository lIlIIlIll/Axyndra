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

private func receiveConfigure111(f: WorkflowChildFixture111): Unit {
    @Expect(f.product.setPluginEnabled(f.namespace,false).isOk())
    File.writeTo(f.root+"/settings/plugins/primitives.json",encodeAgentValue(objectValue([
        ValueField("version",integerValue(1)),ValueField("plugins",listValue([objectValue([
            ValueField("namespace",textValue(f.namespace)),ValueField("package_digest",textValue(f.digest)),
            ValueField("tools",listValue([
                objectValue([ValueField("name",textValue("task")),ValueField("profile",textValue("frozen-primitives-v1")),
                    ValueField("services",listValue([textValue("child.start")])),ValueField("preparation_provider",textValue("prepare_child"))]),
                objectValue([ValueField("name",textValue("hub")),ValueField("profile",textValue("frozen-primitives-v1")),
                    ValueField("services",listValue([textValue("peer.list"),textValue("peer.receive")])),ValueField("preparation_provider",textValue("prepare_child"))]),
                objectValue([ValueField("name",textValue("hub_messages")),
            ValueField("profile",textValue("frozen-primitives-v1")),ValueField("services",listValue([textValue("peer.send"),textValue("peer.wait")])),
            ValueField("preparation_provider",textValue("prepare_child")),ValueField("invocation_capability",objectValue([ValueField("catalog",textValue("workspace.read")),ValueField("services",objectValue([ValueField("peer.send",textValue("peer.message")),ValueField("peer.wait",textValue("workspace.read"))]))]))])]))])]))])).toArray())
    @Expect(f.product.setPluginEnabled(f.namespace,true).isOk())
}
private func receiveCall111(f: WorkflowChildFixture111,id: String,peek: Bool): ToolCall {
    ToolCall(id,"plugin."+f.namespace+".hub",objectValue([ValueField("op",textValue("inbox")),ValueField("peek",boolValue(peek))]))
}
private func seedActualChildMail111(f: WorkflowChildFixture111,thread: SessionId): Unit {
    // Seed through a real child model ToolCall and the existing canonical peer
    // sender through the separately selected Native peer-message contribution.
    f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("mail-from-actual-child","plugin."+f.namespace+".hub_messages",objectValue([
        ValueField("op",textValue("send")),ValueField("to",textValue("Main")),
        ValueField("message",textValue("actual child mail 雪"))]))
    let result=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(thread,f.capabilities(),f.call(thread.value),budget:f.budget()))
    try{@Expect(!result.isError);expectCanonicalReturnedReceipt(f.database,result)}finally{result.releasePayload()}
    let roots=ProductTaskPersistence(f.database).loadAll()
    @Expect(roots.size,1);@Expect(roots[0].messages.size,1)
    @Expect(roots[0].messages[0].snapshot.message,"actual child mail 雪")
    @Expect(!roots[0].messages[0].consumed)
    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts receipt JOIN operation_effect_records effect ON effect.operation_id=receipt.operation_id WHERE effect.tool_id='plugin.axyndra:workflow.hub_messages' AND receipt.outcome='completed'"),1)
}
private func receiveResult111(f: WorkflowChildFixture111,thread: SessionId,id: String,peek: Bool): ToolResult {
    hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(thread,f.capabilities(delegate:false),receiveCall111(f,id,peek),budget:f.budget()))
}

@Test
class InstalledWorkflowPeerReceiveTests111 {
    @TestCase
    func actualChildMailPeekKeepsExactIdentityThenConsumePersistsOnlyOnce(): Unit {
        let f=WorkflowChildFixture111();let thread=SessionId("peer-receive-owner")
        try {
            receiveConfigure111(f);seedActualChildMail111(f,thread)
            var previous=""
            for(id in ["peek-one","peek-two","take-one"]){
                let result=receiveResult111(f,thread,id,id!="take-one")
                try {
                    @Expect(!result.isError);expectCanonicalReturnedReceipt(f.database,result)
                    let items=result.output.field("inbox").getOrThrow().items
                    @Expect(items.size,1);@Expect(httpIntentText(items[0],"message"),"actual child mail 雪")
                    @Expect(items[0].field("replyTo").isNone())
                    if(previous!=""){@Expect(encodeAgentValue(items[0]),previous)}else{previous=encodeAgentValue(items[0])}
                }finally{result.releasePayload()}
                let roots=ProductTaskPersistence(f.database).loadAll()
                @Expect(roots[0].messages[0].consumed,id=="take-one")
            }
            let empty=receiveResult111(f,thread,"take-empty",false)
            try{@Expect(!empty.isError);@Expect(empty.output.field("inbox").getOrThrow().items.size,0)}finally{empty.releasePayload()}
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),6)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome IN ('unknown','rejected')"),0)
        }finally{f.close()}
    }
    @TestCase
    func foreignThreadHasEmptyMailboxAndCannotConsumeTheOriginalOwnersMessage(): Unit {
        let f=WorkflowChildFixture111();let owner=SessionId("peer-mail-owner")
        try {
            receiveConfigure111(f);seedActualChildMail111(f,owner)
            let foreignResult=receiveResult111(f,SessionId("peer-mail-foreign"),"foreign-receive",false)
            try{@Expect(!foreignResult.isError);@Expect(foreignResult.output.field("inbox").getOrThrow().items.size,0)}finally{foreignResult.releasePayload()}
            @Expect(!ProductTaskPersistence(f.database).loadAll()[0].messages[0].consumed)
            let actual=receiveResult111(f,owner,"actual-receive",false)
            try{@Expect(!actual.isError);@Expect(actual.output.field("inbox").getOrThrow().items.size,1)}finally{actual.releasePayload()}
            @Expect(ProductTaskPersistence(f.database).loadAll()[0].messages[0].consumed)
        }finally{f.close()}
    }
    @TestCase
    func actualSnapshotWriteFailureRestoresConsumedBitAndNeverCreatesCompletedReceiveReceipt(): Unit {
        let f=WorkflowChildFixture111();let owner=SessionId("peer-mail-rollback")
        var trigger=false
        try {
            receiveConfigure111(f);seedActualChildMail111(f,owner)
            f.database.execute("CREATE TRIGGER deny_peer_take_111 BEFORE UPDATE ON task_snapshots WHEN instr(NEW.payload,'\"consumed\":true')>0 BEGIN SELECT RAISE(ABORT,'peer take persistence denied'); END")
            trigger=true
            let result=f.product.vnext.executeCanonicalTool(owner,f.capabilities(delegate:false),receiveCall111(f,"take-fails",false),budget:f.budget())
            match(result){case Result.Err(_)=>();case Result.Ok(ToolInvocationResult.Completed(value))=>try{@Expect(value.isError)}finally{value.releasePayload()};case _=>@Expect(false)}
            let saved=ProductTaskPersistence(f.database).loadAll()
            @Expect(saved.size,1);@Expect(!saved[0].messages[0].consumed)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts receipt JOIN operation_effect_records effect ON effect.operation_id=receipt.operation_id WHERE effect.tool_id='host.child.start' AND receipt.outcome='unknown'"),1)
            // The earlier real child.start and Native peer.send each have a Completed hidden Receipt.
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts receipt JOIN operation_effect_records effect ON effect.operation_id=receipt.operation_id WHERE effect.tool_id='host.child.start' AND receipt.outcome='completed'"),2)
        }finally{
            if(trigger){f.database.execute("DROP TRIGGER deny_peer_take_111")}
            f.close()
        }
    }
}
