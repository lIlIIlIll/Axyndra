package workflow_plugin

import agent_domain.*
import std.unittest.*
import std.collection.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func peerResumePayload111(value:AgentValue):AgentValue {
    let raw=encodeAgentValue(value);let digest=modelPolicySha256Text(raw)
    objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_PAYLOAD_SCHEMA)),
        ValueField("artifact_ref",textValue("blob:sha256:"+digest)),ValueField("encoding",textValue("utf8")),
        ValueField("bytes",integerValue(raw.size)),ValueField("sha256",textValue(digest)),
        ValueField("content_type",textValue("text/plain; charset=utf-8"))])
}
func peerResumeSnapshot111():AgentValue {
    objectValue([ValueField("schema",textValue("axyndra.peer-member-snapshot/v1")),ValueField("sender",textValue("Main")),
        ValueField("sender_session",textValue("root")),ValueField("root_thread",textValue("root")),
        ValueField("root_revision",integerValue(9)),ValueField("id",textValue("custom-label")),
        ValueField("thread_id",textValue("child-thread")),ValueField("run_id",textValue("prior-child")),
        ValueField("status",textValue("completed")),ValueField("source_identity",textValue("plugin:historical-data")),
        ValueField("updated_at",integerValue(90)),ValueField("execution_in_progress",boolValue(false)),
        ValueField("launch_in_progress",boolValue(false)),ValueField("finishing",boolValue(false)),
        ValueField("budget_held",boolValue(false)),ValueField("completion_done",boolValue(true))])
}
func peerResumeQuery111(role:String,body!:String="保留\u{0000}<message>\nline"):AgentValue {
    let digest=modelPolicySha256Text("peer-data")
    let binding=objectValue([ValueField("namespace",textValue("axyndra:workflow")),
        ValueField("package_digest",textValue("sha256:"+digest)),ValueField("generation",textValue("7")),
        ValueField("configuration_digest",textValue(digest)),ValueField("thread_id",textValue("root")),
        ValueField("lane_id",textValue("main")),ValueField("run_id",textValue("new-parent")),ValueField("epoch",integerValue(4)),
        ValueField("parent_call_id",textValue("send-call")),ValueField("contribution",textValue("plugin.axyndra:workflow.hub")),
        ValueField("implementation_fingerprint",textValue("primitive:"+digest)),ValueField("schema_digest",textValue(digest))])
    let business=objectValue([ValueField("op",textValue("send")),ValueField("to",textValue("custom-label")),
        ValueField("message",textValue(body)),ValueField("replyTo",textValue("older-message"))])
    let request=objectValue([ValueField("schema",textValue(PLUGIN_PEER_READ111)),ValueField("binding",binding),
        ValueField("projection_digest",textValue(digest)),ValueField("recipient",textValue("custom-label")),
        ValueField("input_payload",peerResumePayload111(business)),ValueField("member_snapshot",peerResumeSnapshot111()),
        ValueField("invocation_capability",textValue("peer.message"))])
    let recipe=objectValue([ValueField("schema",textValue("axyndra.workflow-child-completion/v1")),
        ValueField("arguments",objectValue([ValueField("agent",textValue(role)),ValueField("name",textValue("custom-label")),
            ValueField("task",textValue("original task"))])),ValueField("batch",boolValue(false))])
    let definition=objectValue([ValueField("request",objectValue([])),ValueField("completion",objectValue([
        ValueField("provider",textValue("prepare_child")),ValueField("input",recipe),
        ValueField("input_sha256",textValue(modelPolicySha256Text(canonicalAgentValue(recipe))))]))])
    let target=objectValue([ValueField("id",textValue("custom-label")),ValueField("thread_id",textValue("child-thread")),
        ValueField("run_id",textValue("prior-child")),ValueField("status",textValue("completed")),
        ValueField("source_identity",textValue("plugin:historical-data")),ValueField("capability_ceiling",listValue([])),
        ValueField("definition",definition)])
    let observed=objectValue([ValueField("sender",textValue("Main")),ValueField("sender_session",textValue("root")),
        ValueField("root_thread",textValue("root")),ValueField("counter",integerValue(8)),ValueField("target",target),
        ValueField("message",objectValue([ValueField("id",textValue("message-frozen-9")),ValueField("input_payload",request.field("input_payload").getOrThrow()),ValueField("created_at",integerValue(100))]))])
    let fact=objectValue([ValueField("schema",textValue(PLUGIN_PEER_READ_RESULT111)),ValueField("binding",binding),
        ValueField("projection_digest",textValue(digest)),ValueField("request_sha256",textValue(modelPolicySha256Text(canonicalAgentValue(request)))),
        ValueField("observation",observed)])
    objectValue([ValueField("schema",textValue("axyndra.peer-resume-preparation/v1")),ValueField("request",request),ValueField("fact",fact),ValueField("input",business)])
}

@Test
class WorkflowPeerResumePolicy111Tests {
    @TestCase
    func allOriginalRolesUseOriginalPromptAlgorithmAndDoNotChooseModelDefaults():Unit {
        for(name in ["task","scout","designer","reviewer","librarian","sonic"]) {
            let query=peerResumeQuery111(name);let before=canonicalAgentValue(query)
            let proposal=workflowPeerResumeProposal111(query);let request=proposal.field("request").getOrThrow()
            let role=workflowRoleValue(name)
            let builder=PromptBuilder()
            builder.add(PromptSection(PromptSectionKind.Base,PromptTrust.System,PromptStability.Stable,
                workflowText(role,"source"),workflowText(role,"version"),workflowText(role,"prompt")))
            let expected=builder.build()
            @Expect(httpIntentText(request,"system_prompt"),expected.text)
            @Expect(httpIntentText(request,"cache_key"),expected.stablePrefixHash)
            @Expect(canonicalAgentValue(request.field("capability_ceiling").getOrThrow()),canonicalAgentValue(role.field("capability_ceiling").getOrThrow()))
            @Expect(canonicalAgentValue(request.field("requested_limits").getOrThrow()),canonicalAgentValue(role.field("requested_limits").getOrThrow()))
            @Expect(request.field("model_alias").isNone());@Expect(request.field("thinking").isNone())
            @Expect(canonicalAgentValue(query),before)
        }
    }
    @TestCase
    func fullOriginalMessageTextAndFrozenIdentityRemainInTheNewPrompt():Unit {
        let query=peerResumeQuery111("scout")
        let proposal=workflowPeerResumeProposal111(query)
        @Expect(httpIntentText(proposal.field("request").getOrThrow(),"prompt"),
            "<hub-message from=\"Main\" id=\"message-frozen-9\">保留\u{0000}<message>\nline</hub-message>")
        @Expect(httpIntentText(proposal,"fact_sha256"),modelPolicySha256Text(canonicalAgentValue(query.field("fact").getOrThrow())))
        @Expect(httpIntentText(proposal.field("target").getOrThrow(),"id"),"custom-label")
        @Expect(httpIntentText(proposal.field("message").getOrThrow(),"reply_to"),"older-message")
    }
    @TestCase
    func liveRecoveryAndForeignObservationCannotBecomeResumeData():Unit {
        for(status in ["running","blocked","recovery_required"]) {
            let query=peerResumeQuery111("task")
            query.field("fact").getOrThrow().field("observation").getOrThrow().field("target").getOrThrow().put("status",textValue(status))
            var denied=false
            try {let _=workflowPeerResumeProposal111(query)}catch(_:Exception){denied=true}
            @Expect(denied)
        }
        for(field in ["recipient","input_payload","invocation_capability"]) {
            let query=peerResumeQuery111("scout")
            query.field("request").getOrThrow().put(field,textValue("changed"))
            var denied=false
            try {let _=workflowPeerResumeProposal111(query)}catch(_:Exception){denied=true}
            @Expect(denied)
        }
    }
    @TestCase
    func compactReadNeverTruncatesOriginalMessageAndRejectsSameSizeBodyDrift():Unit {
        let body=String.fromUtf8(Array<UInt8>(131072,repeat:0)) + "終"
        let query=peerResumeQuery111("scout",body:body)
        let request=query.field("request").getOrThrow()
        @Expect(encodeAgentValue(request).size<16384)
        @Expect(encodeAgentValue(query.field("input").getOrThrow()).size>65536)
        let result=workflowPeerResumeProposal111(query)
        @Expect(httpIntentText(result.field("message").getOrThrow(),"body"),body)
        @Expect(httpIntentText(result.field("request").getOrThrow(),"prompt"),
            "<hub-message from=\"Main\" id=\"message-frozen-9\">"+body+"</hub-message>")
        query.field("input").getOrThrow().put("message",textValue(body[..body.size-3]+"末"))
        var denied=false
        try{let _=workflowPeerResumeProposal111(query)}catch(_:Exception){denied=true}
        @Expect(denied)
    }
    @TestCase
    func actualPureDispatcherSelectsOnlyMemberReadsWithoutBodyOrAuthority():Unit {
        let business=peerResumeQuery111("scout").field("input").getOrThrow()
        for(target in ["custom-label","Main","all"]){
            business.put("to",textValue(target));let before=encodeAgentValue(business)
            let result=workflowChildPolicy111("prepare_child",objectValue([
                ValueField("schema",textValue("axyndra.primitive-read-query/v1")),ValueField("tool",textValue("hub")),
                ValueField("input",business)]))
            @Expect(httpIntentExactFields(result,["peer_read"]))
            let selected=result.field("peer_read").getOrThrow()
            if(target=="custom-label"){@Expect(httpIntentExactFields(selected,["recipient"]))
                @Expect(httpIntentText(selected,"recipient"),target)}else{@Expect(selected.unifiedKind,ValueKind.Null)}
            @Expect(encodeAgentValue(business),before)
        }
        let query=peerResumeQuery111("scout")
        @Expect(canonicalAgentValue(workflowChildPolicy111("prepare_child",query)),
            canonicalAgentValue(workflowPeerResumeProposal111(query)))
    }
    @TestCase
    func alteredPriorRoleRecipeFailsItsFrozenDigest():Unit {
        let query=peerResumeQuery111("scout")
        let completion=query.field("fact").getOrThrow().field("observation").getOrThrow().field("target").getOrThrow()
            .field("definition").getOrThrow().field("completion").getOrThrow()
        completion.field("input").getOrThrow().field("arguments").getOrThrow().put("agent",textValue("task"))
        var denied=false
        try {let _=workflowPeerResumeProposal111(query)}catch(_:Exception){denied=true}
        @Expect(denied)
    }
}

@Test
class WorkflowPeerReadSelection111Tests {
    @TestCase
    func liveAndBlockedOriginalDeliveryDoesNotRequestAnotherRead():Unit {
        for(status in ["running","blocked"]) {
            let snapshot=peerResumeSnapshot111();snapshot.put("status",textValue(status))
            snapshot.put("execution_in_progress",boolValue(true));snapshot.put("budget_held",boolValue(true))
            snapshot.put("completion_done",boolValue(false))
            let query=objectValue([ValueField("schema",textValue("axyndra.peer-read-selection/v1")),
                ValueField("selector",objectValue([ValueField("recipient",textValue("custom-label"))])),ValueField("snapshot",snapshot)])
            let before=canonicalAgentValue(query)
            let selected=workflowChildPolicy111("prepare_child",query)
            @Expect(httpIntentExactFields(selected,["peer_read"]))
            @Expect(selected.field("peer_read").getOrThrow().unifiedKind,ValueKind.Null)
            @Expect(canonicalAgentValue(query),before)
        }
    }
    @TestCase
    func onlySettledTerminalSnapshotRequestsMoreVerificationAndNoStart():Unit {
        for(status in ["completed","failed","cancelled"]) {
            let snapshot=peerResumeSnapshot111();snapshot.put("status",textValue(status))
            let selector=objectValue([ValueField("recipient",textValue("custom-label"))])
            let query=objectValue([ValueField("schema",textValue("axyndra.peer-read-selection/v1")),
                ValueField("selector",selector),ValueField("snapshot",snapshot)])
            let selected=workflowChildPolicy111("prepare_child",query)
            @Expect(httpIntentExactFields(selected,["peer_read"]))
            @Expect(canonicalAgentValue(selected.field("peer_read").getOrThrow()),canonicalAgentValue(selector))
            for(field in ["execution_in_progress","launch_in_progress","finishing","budget_held","completion_done"]) {
                let saved=snapshot.field(field).getOrThrow().asBool();snapshot.put(field,boolValue(!saved))
                var denied=false
                try{let _=workflowChildPolicy111("prepare_child",query)}catch(_:Exception){denied=true}
                @Expect(denied);snapshot.put(field,boolValue(saved))
            }
            for(field in ["id","schema"]) {
                let saved=snapshot.field(field).getOrThrow();snapshot.put(field,textValue("foreign"))
                var denied=false
                try{let _=workflowChildPolicy111("prepare_child",query)}catch(_:Exception){denied=true}
                @Expect(denied);snapshot.put(field,saved)
            }
            snapshot.put("status",textValue("recovery_required"))
            var denied=false
            try{let _=workflowChildPolicy111("prepare_child",query)}catch(_:Exception){denied=true}
            @Expect(denied)
        }
    }
}

@Test
class WorkflowPeerFrozenMember111Tests {
    @TestCase
    func ordinaryMemberPlanBindsSameSnapshotAndExactOriginalMessage():Unit {
        let snapshot=peerResumeSnapshot111();snapshot.put("status",textValue("blocked"))
        snapshot.put("execution_in_progress",boolValue(true));snapshot.put("budget_held",boolValue(true))
        snapshot.put("completion_done",boolValue(false))
        let business=peerResumeQuery111("task").field("input").getOrThrow()
        let query=objectValue([ValueField("schema",textValue("axyndra.peer-member-preparation/v1")),
            ValueField("input",business),ValueField("snapshot",snapshot)])
        let before=canonicalAgentValue(query)
        let prepared=workflowChildPolicy111("prepare_child",query)
        let input=prepared.field("intents").getOrThrow().items[0].field("input").getOrThrow()
        @Expect(canonicalAgentValue(input.field("member_snapshot").getOrThrow()),canonicalAgentValue(snapshot))
        @Expect(httpIntentText(input,"body"),httpIntentText(business,"message"))
        @Expect(httpIntentText(input,"reply_to"),httpIntentText(business,"replyTo"))
        @Expect(canonicalAgentValue(query),before)
        snapshot.put("status",textValue("completed"))
        var denied=false
        try{let _=workflowChildPolicy111("prepare_child",query)}catch(_:Exception){denied=true}
        @Expect(denied)
    }
}
