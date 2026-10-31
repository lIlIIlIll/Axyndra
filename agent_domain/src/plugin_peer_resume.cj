package agent_domain

import yjson.*
import yjson_support.*

// This is a descriptive subset of one frozen peer.send plan. It supplies no
// live source. Store must prove its original completed read at each handoff.
public func pluginPeerResumeInputValid111(input:AgentValue,binding:AgentValue):Bool {
    try {
        if(!httpIntentExactFields(input,["recipient","body","reply_to","format","resume"])) {return false}
        let resume=input.field("resume").getOrThrow()
        if(!httpIntentExactFields(resume,["read_request","read_fact","proposal"])){return false}
        let request=resume.field("read_request").getOrThrow();let fact=resume.field("read_fact").getOrThrow()
        let proposal=resume.field("proposal").getOrThrow()
        if(!pluginPeerReadResultValid111(fact,request) ||
            canonicalAgentValue(request.field("binding").getOrThrow())!=canonicalAgentValue(binding) ||
            !httpIntentExactFields(proposal,["schema","fact_sha256","target","message","request","completion"]) ||
            httpIntentText(proposal,"schema")!="axyndra.peer-resume-proposal/v1" ||
            httpIntentText(proposal,"fact_sha256")!=modelPolicySha256Text(canonicalAgentValue(fact))) {return false}
        let observed=fact.field("observation").getOrThrow();let target=observed.field("target").getOrThrow()
        let identity=observed.field("message").getOrThrow();let message=proposal.field("message").getOrThrow()
        let recipient=input.field("recipient").getOrThrow()
        if(httpIntentText(recipient,"kind")!="member" || httpIntentText(recipient,"id")!=httpIntentText(target,"id") ||
            !["completed","failed","cancelled"].contains(httpIntentText(target,"status")) ||
            canonicalAgentValue(proposal.field("target").getOrThrow())!=canonicalAgentValue(target) ||
            !httpIntentExactFields(message,["id","body","reply_to","created_at"]) ||
            httpIntentText(message,"id")!=httpIntentText(identity,"id") ||
            canonicalAgentValue(message.field("created_at").getOrThrow())!=canonicalAgentValue(identity.field("created_at").getOrThrow()) ||
            canonicalAgentValue(message.field("body").getOrThrow())!=canonicalAgentValue(input.field("body").getOrThrow()) ||
            canonicalAgentValue(message.field("reply_to").getOrThrow())!=canonicalAgentValue(input.field("reply_to").getOrThrow()) ||
            canonicalAgentValue(proposal.field("completion").getOrThrow())!=
                canonicalAgentValue(target.field("definition").getOrThrow().field("completion").getOrThrow())) {return false}
        let next=proposal.field("request").getOrThrow()
        if(!httpIntentExactFields(next,["prompt","system_prompt","cache_key","capability_ceiling","requested_limits"])) {return false}
        for(field in ["prompt","system_prompt","cache_key"]) {
            if(next.field(field).getOrThrow().unifiedKind!=ValueKind.Text){return false} }
        next.field("capability_ceiling").getOrThrow().unifiedKind==ValueKind.List &&
            next.field("requested_limits").getOrThrow().unifiedKind==ValueKind.Object && httpIntentText(next,"prompt")!=""
    }catch(_:Exception){false}
}
public func pluginPeerResumeParentMatches111(parent:AgentValue,input:AgentValue):Bool {
    try {
        let binding=parent.field("host_plan").getOrThrow().field("binding").getOrThrow()
        if(!pluginPeerResumeInputValid111(input,binding)){return false}
        let original=parent.field("input").getOrThrow()
        let envelope=original.field(CONTEXT_READ_INPUT_FIELD).getOrThrow()
        let links=contextReadFactLinksFromValue(envelope.field("facts").getOrThrow())
        let resume=input.field("resume").getOrThrow()
        links.size==1 && validateContextReadInputProjection(original,links).isOk() &&
            links[0].runId.value==httpIntentText(binding,"run_id") &&
            canonicalAgentValue(envelope.field("data").getOrThrow())==canonicalAgentValue(resume.field("read_fact").getOrThrow()) &&
            pluginPeerReadInputMatches111(contextReadBusinessInput(original),resume.field("read_request").getOrThrow())
    }catch(_:Exception){false}
}
