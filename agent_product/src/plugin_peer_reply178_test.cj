package agent_product

import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func peerReplyCapabilities178(f:WorkflowChildFixture111):CapabilitySet {
    CapabilitySet(values:[Capability(CapabilityKind.ExtensionInvoke,resource:f.namespace),
        Capability(CapabilityKind.WorkspaceRead),Capability(CapabilityKind.PeerMessage)])
}
func peerReplyCall178(f: WorkflowChildFixture111, id: String, target: String, timeout: Int64): ToolCall {
    ToolCall(id,"plugin."+f.namespace+".hub",objectValue([ValueField("op",textValue("send")),
        ValueField("to",textValue(target)),ValueField("message",textValue("original awaited request 雪\\\"\n")),
        ValueField("replyTo",textValue("old-parent-178")),ValueField("await",boolValue(true)),
        ValueField("timeoutMs",integerValue(timeout))]))
}
func peerReplyStoredRequest178(f: WorkflowChildFixture111, target: String): Bool {
    let roots=ProductTaskPersistence(f.database).loadAll()
    for(root in roots){for(message in root.messages){
        if(message.snapshot.from=="Main" && message.snapshot.to==target &&
            message.snapshot.message=="original awaited request 雪\\\"\n"){return true} }}
    false
}
func peerReplyWaitForPublication178(f: WorkflowChildFixture111, target: String): Unit {
    for(_ in 0..1000){if(peerReplyStoredRequest178(f,target)){return};sleep(Duration.millisecond*5)}
    @Expect(false)
}
func peerReplyLaunchActualReceiver178(f:WorkflowChildFixture111, probe:JobWaitHeldTool166, thread:SessionId):String {
    peerWaitSelection171(f);jobWaitInstall166(f,probe)
    f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("actual-reply-send-178","plugin."+f.namespace+".hub",objectValue([
        ValueField("op",textValue("send")),ValueField("to",textValue("Main")),
        ValueField("message",textValue("actual whole reply 雪\\\"\n")),ValueField("replyTo",textValue("actual-parent-178"))]))
    let launch=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(thread,f.capabilities(),
        childBackgroundCall111(f,thread.value),budget:f.budget()))
    try{@Expect(!launch.isError);expectCanonicalReturnedReceipt(f.database,launch)}finally{launch.releasePayload()}
    jobWaitEntered166(probe)
    let jobs=f.product.asyncJobs(thread);@Expect(jobs.size,1)
    jobs[0].agentId
}

@Test
class InstalledWorkflowActualPeerReply178Tests {
    @TestCase
    func actualSendThenUnboundedReplyPreservesWholeOriginalOutputAndOnePublication178():Unit {
        let f=WorkflowChildFixture111(asynchronous:true);let probe=JobWaitHeldTool166()
        let thread=SessionId("actual-peer-reply-owner-178")
        try {
            let target=peerReplyLaunchActualReceiver178(f,probe,thread)
            let admitted=f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions")
            let returned=AtomicBool(false)
            let work=spawn{try{f.product.vnext.executeCanonicalTool(thread,peerReplyCapabilities178(f),
                peerReplyCall178(f,"original-awaited-send-178",target,0),budget:f.budget())}finally{returned.store(true)}}
            var joined=false
            try {
                peerReplyWaitForPublication178(f,target)
                jobWaitActualDerived166(f,admitted+1)
                jobWaitActualExecuting166(f,"original-awaited-send-178")
                // Existing 30-second Native watchdog is not this Kernel wait.
                sleep(Duration.second*31)
                @Expect(!returned.load());@Expect(probe.calls.load(),1);@Expect(!probe.returned.load())
                probe.released.store(true)
                let result=hostServiceEntryCompleted(work.get());joined=true
                try {
                    @Expect(!result.isError);@Expect(result.payloadLease.isSome())
                    @Expect(httpIntentText(result.output,"op"),"send");@Expect(httpIntentText(result.output,"from"),"Main")
                    let receipts=result.output.field("receipts").getOrThrow().items
                    @Expect(receipts.size,1);@Expect(httpIntentText(receipts[0],"to"),target)
                    @Expect(receipts[0].field("delivered").getOrThrow().asBool())
                    let roots=ProductTaskPersistence(f.database).loadAll();@Expect(roots.size,1)
                    @Expect(roots[0].messages.size,2)
                    let request=roots[0].messages[0];let reply=roots[0].messages[1]
                    @Expect(httpIntentText(receipts[0],"id"),request.snapshot.id)
                    @Expect(request.snapshot.from,"Main");@Expect(request.snapshot.to,target)
                    @Expect(request.snapshot.message,"original awaited request 雪\\\"\n")
                    @Expect(request.snapshot.replyTo,"old-parent-178")
                    @Expect(reply.consumed);@Expect(reply.snapshot.from,target)
                    @Expect(encodeAgentValue(result.output.field("waited").getOrThrow()),encodeAgentValue(hubMessageValue(reply.snapshot)))
                    @Expect(reply.snapshot.message,"actual whole reply 雪\\\"\n")
                    @Expect(reply.snapshot.replyTo,"actual-parent-178")
                    expectCanonicalReturnedReceipt(f.database,result)
                }finally{result.releasePayload()}
                @Expect(probe.returned.load());@Expect(probe.calls.load(),1)
            }finally{probe.released.store(true);if(!joined){let _=work.get()}}
        }finally{probe.released.store(true);f.close()}
    }
    @TestCase
    func cancelledRealReplyContinuationKeepsOnePublishedRequestAndNoCompletedReplyReceipt178():Unit {
        let f=WorkflowChildFixture111(asynchronous:true);let probe=JobWaitHeldTool166()
        let thread=SessionId("actual-peer-reply-cancel-178")
        let cancellation=CancellationSource();let owner=ProductDirectPreparationOwner({=>cancellation.token.check()})
        try {
            let target=peerReplyLaunchActualReceiver178(f,probe,thread)
            let work=spawn{f.product.vnext.executeDeferredCanonicalTool(thread,peerReplyCapabilities178(f),
                peerReplyCall178(f,"actual-cancel-reply-178",target,0),owner,cancellation.token,budget:f.budget())}
            var joined=false
            try {
                peerReplyWaitForPublication178(f,target);jobWaitActualExecuting166(f,"actual-cancel-reply-178")
                let _=cancellation.cancel();let actual=work.get();joined=true
                match(actual){case Result.Err(_)=>();case Result.Ok(ToolInvocationResult.Completed(value))=>
                    try{@Expect(value.isError)}finally{value.releasePayload()};case Result.Ok(ToolInvocationResult.Denied(_))=>();case _=>@Expect(false)}
                let roots=ProductTaskPersistence(f.database).loadAll();@Expect(roots.size,1);@Expect(roots[0].messages.size,1)
                @Expect(roots[0].messages[0].snapshot.from,"Main");@Expect(roots[0].messages[0].snapshot.to,target)
                @Expect(!roots[0].messages[0].consumed)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts receipt JOIN operation_effect_records effect ON effect.operation_id=receipt.operation_id WHERE effect.tool_id='host.child.start' AND instr(effect.normalized_plan,'actual-cancel-reply-178')>0 AND receipt.outcome='completed'"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'")>0)
                @Expect(!probe.returned.load());@Expect(probe.calls.load(),1)
            }finally{let _=cancellation.cancel();if(!joined){let _=work.get()}}
        }finally{probe.released.store(true);let _=owner.cancel();cancellation.close();f.close()}
    }
    @TestCase
    func realSqlReplyTakeRefusalKeepsPublishedRequestAndWholeUnconsumedReply178():Unit {
        let f=WorkflowChildFixture111(asynchronous:true);let probe=JobWaitHeldTool166()
        let thread=SessionId("actual-peer-reply-sql-178")
        var trigger=false
        try {
            let target=peerReplyLaunchActualReceiver178(f,probe,thread)
            let work=spawn{f.product.vnext.executeCanonicalTool(thread,peerReplyCapabilities178(f),
                peerReplyCall178(f,"actual-sql-reply-178",target,0),budget:f.budget())}
            var joined=false
            try {
                peerReplyWaitForPublication178(f,target);jobWaitActualExecuting166(f,"actual-sql-reply-178")
                f.database.execute("CREATE TRIGGER deny_peer_reply178 BEFORE UPDATE ON task_snapshots WHEN instr(NEW.payload,'\"consumed\":true')>0 BEGIN SELECT RAISE(ABORT,'actual peer reply consumption denied'); END")
                trigger=true;probe.released.store(true)
                let actual=work.get();joined=true
                match(actual){case Result.Err(_)=>();case Result.Ok(ToolInvocationResult.Completed(value))=>
                    try{@Expect(value.isError)}finally{value.releasePayload()};case _=>@Expect(false)}
                let roots=ProductTaskPersistence(f.database).loadAll();@Expect(roots.size,1);@Expect(roots[0].messages.size,2)
                let reply=roots[0].messages[1]
                @Expect(!reply.consumed);@Expect(reply.snapshot.from,target);@Expect(reply.snapshot.to,"Main")
                @Expect(reply.snapshot.message,"actual whole reply 雪\\\"\n");@Expect(reply.snapshot.replyTo,"actual-parent-178")
                @Expect(httpIntentText(hubMessageValue(reply.snapshot),"id"),reply.snapshot.id)
                @Expect(hubMessageValue(reply.snapshot).field("createdAt").getOrThrow().asInt64(),reply.snapshot.createdAt)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts receipt JOIN operation_effect_records effect ON effect.operation_id=receipt.operation_id WHERE effect.tool_id='host.child.start' AND instr(effect.normalized_plan,'actual-sql-reply-178')>0 AND receipt.outcome='completed'"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'")>0)
            }finally{probe.released.store(true);if(!joined){let _=work.get()}}
        }finally{if(trigger){f.database.execute("DROP TRIGGER deny_peer_reply178")};probe.released.store(true);f.close()}
    }
}
