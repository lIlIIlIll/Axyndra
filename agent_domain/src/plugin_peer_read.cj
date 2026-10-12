package agent_domain

import yjson.*
import yjson_support.*

// Frozen coordination data in the existing ContextRead fact chain. This
// dialect supplies neither a child Source nor permission to start a Run.
public let PLUGIN_PEER_READ111 = "axyndra.peer-resume-read/v1"
public let PLUGIN_PEER_READ_RESULT111 = "axyndra.peer-resume-fact/v1"

public func pluginPeerMemberSnapshotValid111(value:AgentValue):Bool {
    try {
        if(!httpIntentExactFields(value,["schema","sender","sender_session","root_thread","root_revision","id","thread_id",
            "run_id","status","source_identity","updated_at","execution_in_progress","launch_in_progress","finishing",
            "budget_held","completion_done"]) || httpIntentText(value,"schema")!="axyndra.peer-member-snapshot/v1") {return false}
        for(field in ["sender","sender_session","root_thread","id","thread_id","run_id","status","source_identity"]) {
            if(value.field(field).getOrThrow().unifiedKind!=ValueKind.Text || httpIntentText(value,field)==""){return false} }
        for(field in ["root_revision","updated_at"]) {
            if(documentContractInteger(value.field(field).getOrThrow())<0){return false} }
        for(field in ["execution_in_progress","launch_in_progress","finishing","budget_held","completion_done"]) {
            if(value.field(field).getOrThrow().unifiedKind!=ValueKind.Boolean){return false} }
        httpIntentText(value,"sender")!=httpIntentText(value,"id")
    }catch(_:Exception){false}
}

public func pluginPeerReadRequestValid111(value: AgentValue): Bool {
    try {
        if (!httpIntentExactFields(value, ["schema", "binding", "projection_digest", "recipient", "input_payload",
            "invocation_capability","member_snapshot"]) || httpIntentText(value,"schema") != PLUGIN_PEER_READ111 ||
            validatePluginDocumentBinding(value.field("binding").getOrThrow()).isError() ||
            !httpIntentDigest(httpIntentText(value,"projection_digest")) ||
            value.field("recipient").getOrThrow().unifiedKind != ValueKind.Text || httpIntentText(value,"recipient") == "" ||
            parsePluginDocumentPayloadReference(value.field("input_payload").getOrThrow()).isError() ||
            !pluginPeerMemberSnapshotValid111(value.field("member_snapshot").getOrThrow()) ||
            httpIntentText(value.field("member_snapshot").getOrThrow(),"id")!=httpIntentText(value,"recipient") ||
            httpIntentText(value.field("member_snapshot").getOrThrow(),"sender_session")!=
                httpIntentText(value.field("binding").getOrThrow(),"thread_id")) { return false }
        let selected=httpIntentText(value,"invocation_capability")
        selected=="peer.message" || selected=="extension.invoke"
    } catch (_:Exception) { false }
}

public func pluginPeerReadAuthority111(plan: NormalizedOperationPlan): Bool {
    if (!pluginPeerReadRequestValid111(plan.canonicalArguments) || !plan.resolvedPaths.isEmpty() ||
        !plan.relevantEnvironment.isEmpty() || !plan.networkPolicy.egress.isEmpty() || !plan.networkPolicy.publish.isEmpty()) {
        return false }
    let selected=httpIntentText(plan.canonicalArguments,"invocation_capability")
    let namespace=httpIntentText(plan.canonicalArguments.field("binding").getOrThrow(),"namespace")
    if (selected=="peer.message") {
        return plan.requiredCapabilities.size==1 && plan.requiredCapabilities[0].kind==CapabilityKind.PeerMessage &&
            plan.requiredCapabilities[0].resource=="" }
    if (plan.requiredCapabilities.size!=2) { return false }
    var peer=false; var invoke=false
    for (capability in plan.requiredCapabilities) {
        if (capability.kind==CapabilityKind.PeerMessage && capability.resource=="" && !peer) { peer=true }
        else if (capability.kind==CapabilityKind.ExtensionInvoke && capability.resource==namespace && !invoke) { invoke=true }
        else { return false }
    }
    peer && invoke
}

public func pluginPeerReadResultValid111(value: AgentValue, request: AgentValue): Bool {
    try {
        if (!pluginPeerReadRequestValid111(request) ||
            !httpIntentExactFields(value,["schema","binding","projection_digest","request_sha256","observation"]) ||
            httpIntentText(value,"schema")!=PLUGIN_PEER_READ_RESULT111 ||
            canonicalAgentValue(value.field("binding").getOrThrow())!=canonicalAgentValue(request.field("binding").getOrThrow()) ||
            httpIntentText(value,"projection_digest")!=httpIntentText(request,"projection_digest") ||
            httpIntentText(value,"request_sha256")!=modelPolicySha256Text(canonicalAgentValue(request))) { return false }
        let observed=value.field("observation").getOrThrow()
        if (!httpIntentExactFields(observed,["sender","sender_session","root_thread","counter","message","target"])) { return false }
        for (field in ["sender","sender_session","root_thread"]) {
            if (observed.field(field).getOrThrow().unifiedKind!=ValueKind.Text || httpIntentText(observed,field)=="") { return false } }
        let message=observed.field("message").getOrThrow()
        let target=observed.field("target").getOrThrow()
        if (!httpIntentExactFields(message,["id","input_payload","created_at"]) ||
            canonicalAgentValue(message.field("input_payload").getOrThrow())!=
                canonicalAgentValue(request.field("input_payload").getOrThrow()) ||
            message.field("id").getOrThrow().unifiedKind!=ValueKind.Text || httpIntentText(message,"id")=="" ||
            message.field("created_at").getOrThrow().unifiedKind!=ValueKind.Number ||
            observed.field("counter").getOrThrow().unifiedKind!=ValueKind.Number ||
            !httpIntentExactFields(target,["id","thread_id","run_id","status","source_identity","capability_ceiling","definition"]) ||
            httpIntentText(target,"id")!=httpIntentText(request,"recipient")) { return false }
        let counter=documentContractInteger(observed.field("counter").getOrThrow())
        if (counter<0 || counter==Int64.Max || documentContractInteger(message.field("created_at").getOrThrow())<1) {
            return false }
        for (field in ["id","thread_id","run_id","status","source_identity"]) {
            if (target.field(field).getOrThrow().unifiedKind!=ValueKind.Text || httpIntentText(target,field)=="") { return false } }
        let snapshot=request.field("member_snapshot").getOrThrow()
        for(field in ["sender","sender_session","root_thread"]) {
            if(httpIntentText(observed,field)!=httpIntentText(snapshot,field)){return false} }
        for(field in ["id","thread_id","run_id","status","source_identity"]) {
            if(httpIntentText(target,field)!=httpIntentText(snapshot,field)){return false} }
        target.field("capability_ceiling").getOrThrow().unifiedKind==ValueKind.List &&
            target.field("definition").getOrThrow().unifiedKind==ValueKind.Object
    } catch (_:Exception) { false }
}

// Content equality only. Actual input custody belongs to the captured Host
// preparation, whose private writer is checked before this data is consumed.
public func pluginPeerReadInputMatches111(value:AgentValue,request:AgentValue):Bool {
    try {
        if(!pluginPeerReadRequestValid111(request) || value.unifiedKind!=ValueKind.Object ||
            value.field(CONTEXT_READ_INPUT_FIELD).isSome()){return false}
        let expected=match(parsePluginDocumentPayloadReference(request.field("input_payload").getOrThrow())) {
            case Result.Err(_)=>return false;case Result.Ok(found)=>found }
        let raw=encodeAgentValue(value)
        raw.size==expected.bytes && modelPolicySha256Text(raw)==expected.digest
    }catch(_:Exception){false}
}
