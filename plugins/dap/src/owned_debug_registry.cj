package dap_plugin

import std.collection.*
import std.time.*
import yjson.*
import yjson_support.*

class DapOwnedDebugHistory {
    private var value: String
    private let charge: DapOwnedDebugRetainedCharge
    private var closed = false
    init(snapshot: JsonNode) {
        let paid = dapOwnedDebugRetainedCharge(snapshot, 8388608)
        let encoded = try {
            let encoded = stringifyUnifiedJson(snapshot)
            require(encoded.size <= 8388608, "dap_plugin.snapshot_limit"); encoded
        } catch (error: Exception) { paid.close(); throw error }
        charge = paid; value = encoded
    }
    func snapshot(): JsonNode { require(!closed, "dap_plugin.session_closed"); parseUnifiedJson(value, maxBytes: 8388608, maxDepth: 64) }
    func close(): Unit { if(closed){return};closed=true;value="";charge.close() }
}

// Native business history, not a Host resource registry. An actual Host lease
// remains separately owned by the existing lifecycle inventory. No ID here is
// accepted by a ProcessPort or used to create Source/approval/permission.
class DapOwnedDebugRegistry {
    private let limits: ProtocolLimits
    private let history = ArrayList<DapOwnedDebugHistory>()
    private var active: ?DapOwnedDebugSession = None
    private var workflow: ?DapOwnedDebugWorkflow = None
    private var identity: ?JsonNode = None
    private var nextSession: Int64 = 0
    private var publishedTerminal = false
    private var discardFailedStartup = false
    private var closed = false
    init(limits: ProtocolLimits) { this.limits = limits }

    func handle(invocation: JsonNode, args: JsonNode, deadline: MonoTime): SessionReply {
        require(!closed, "dap_plugin.session_closed")
        let action = text(args, "action")
        if (action == "channel_prepare") { return dapOwnedDebugPrepare(args, active) }
        if (action == "channel_abort" && workflow.isNone()) { return dapOwnedDebugAborted(args, active) }
        if (action == "debug_begin" || action == "channel_begin") { return begin(invocation, args, deadline) }
        require(workflow.isSome() && identity.isSome(), "dap_plugin.workflow_missing")
        for (name in ["thread_id", "run_id", "epoch", "operation_id", "call_id"]) {
            require(sameJson(field(invocation, name), field(identity.getOrThrow(), name)), "dap_plugin.workflow_identity_changed")
        }
        let current = workflow.getOrThrow()
        match (action) {
            case "channel_abort" =>
                exact(args,["action","input","configuration","reason"])
                current.abortProposal(text(args,"reason"))
            case "debug_next" | "channel_next" => exact(args, ["action"])
            case "debug_validate" | "channel_validate" => exact(args, ["action", "sequence"]); current.validateEffect(number(args, "sequence"))
                return SessionReply(jsonObject([JsonObjectEntry("valid", jsonBool(true))]))
            case "debug_effect" | "channel_effect" => exact(args, ["action", "sequence", "result"]); current.acknowledge(number(args, "sequence"), field(args, "result"))
            case "debug_reject" | "channel_reject" => exact(args, ["action", "sequence"]); current.reject(number(args, "sequence"))
            case "debug_read" | "channel_read" =>
                exact(args, ["action", "stream", "bytes_hex", "eof"])
                require(text(args, "stream") == "stdout" || text(args, "stream") == "stderr", "dap_plugin.stream_invalid")
                let bytes = unhex(text(args, "bytes_hex"), 16384)
                require(field(args, "eof").unifiedKind == UnifiedJsonKind.Boolean, "dap_plugin.read_invalid")
                current.receiveStream(text(args,"stream"),bytes,boolean(args,"eof"))
            case _ => throw PluginFailure("dap_plugin.workflow_action_invalid")
        }
        reply(current)
    }
    private func begin(invocation: JsonNode, args: JsonNode, deadline: MonoTime): SessionReply {
        if(text(args,"action")=="channel_begin"){exact(args,["action","input","configuration"])}
        else{exact(args,["action","input","configuration","locations"])}
        require(workflow.isNone(), "dap_plugin.workflow_overlap")
        let input = field(args, "input")
        require(input.unifiedKind == UnifiedJsonKind.Object && stringifyUnifiedJson(input).size <= limits.input, "dap_plugin.input_limit")
        let action = debugRequiredText(input, "action").trimAscii().toAsciiLower()
        require(debugActionNames().contains(action), "tool.invalid_argument")
        let timeout = debugInteger(input, "timeout", 30)
        require(timeout >= 1 && timeout <= 3600, "tool.invalid_argument")
        if (action == "sessions" && (active.isNone() || active.getOrThrow().unknown || active.getOrThrow().closed)) {
            return SessionReply(complete(sessionsResult()))
        }
        if (active.isNone() && action == "terminate") {
            return SessionReply(complete(jsonObject([JsonObjectEntry("content", jsonString("No debug session to terminate.")),
                JsonObjectEntry("action", jsonString("terminate")), JsonObjectEntry("success", jsonBool(true))])))
        }
        let observed = if(text(args,"action")=="channel_begin") {
            dapOwnedDebugObservedLocations(input,field(args,"configuration"),active)
        } else {
            let value=field(args,"locations");exact(value,["cwd","program","source"])
            DapDebugLocations(text(value,"cwd"),program:text(value,"program"),source:text(value,"source"))
        }
        if (action == "launch" || action == "attach") {
            require(active.isNone(), "tool.debug_active_session")
            let locations = observed
            require(nextSession < Int64.Max, "dap_plugin.session_sequence_limit")
            nextSession++
            let configured=field(args,"configuration")
            if(field(configured,"adapters").unifiedKind==UnifiedJsonKind.Null){
                let requested=debugText(input,"adapter")
                require(requested=="" || requested==text(configured,"adapter"),"tool.debug_adapter_unavailable")
                active=Some(DapOwnedDebugSession("debug-"+nextSession.toString(),configured,locations,limits.result))
            }else{
                let payment=dapOwnedDebugRetainedCharge(configured,8388608)
                var selected:?JsonNode=None<JsonNode>
                try{selected=Some(dapOwnedSelectAdapter(input,configured))
                    active=Some(DapOwnedDebugSession("debug-"+nextSession.toString(),selected.getOrThrow(),locations,limits.result))}
                finally{selected=None<JsonNode>;payment.close()}}
            discardFailedStartup = true
        }
        require(active.isSome() && !active.getOrThrow().unknown && !active.getOrThrow().closed, "tool.debug_no_session")
        // Neither a fresh phase invocation nor an approval resume extends this
        // original finite command window. Waiting holds a descriptive stage.
        let until = minTime(deadline, MonoTime.now() + Duration.millisecond * timeout * 1000)
        let selected = DapOwnedDebugWorkflow(active.getOrThrow(), input, until, limits.request, locations:Some(observed))
        workflow = Some(selected)
        identity = Some(jsonObject([JsonObjectEntry("thread_id", field(invocation, "thread_id")),
            JsonObjectEntry("run_id", field(invocation, "run_id")), JsonObjectEntry("epoch", field(invocation, "epoch")),
            JsonObjectEntry("operation_id", field(invocation, "operation_id")), JsonObjectEntry("call_id", field(invocation, "call_id"))]))
        reply(selected)
    }
    private func reply(value: DapOwnedDebugWorkflow): SessionReply {
        let result = value.next()
        publishedTerminal = text(result, "status") == "complete"
        if (publishedTerminal && !boolean(result, "is_error")) {
            discardFailedStartup = false
            if(value.commandAction() == "sessions"){return SessionReply(complete(sessionsResult()))}
        }
        SessionReply(result, ok: text(result, "status") != "unknown")
    }
    private func complete(value: JsonNode): JsonNode {
        jsonObject([JsonObjectEntry("status", jsonString("complete")), JsonObjectEntry("result", value), JsonObjectEntry("is_error", jsonBool(false))])
    }
    private func sessionsResult(): JsonNode {
        let values = ArrayList<JsonNode>(); var content = ""
        for (item in history) {
            let value = item.snapshot(); values.add(value)
            if (content != "") { content += "\n" }; content += formatDebugSnapshot(value)
        }
        match (active) { case Some(item) => let value = item.snapshot(); values.add(value)
            if (content != "") { content += "\n" }; content += formatDebugSnapshot(value)
            case None => () }
        if (content == "") { content = "No debug sessions." }
        jsonObject([JsonObjectEntry("content", jsonString(content)), JsonObjectEntry("action", jsonString("sessions")),
            JsonObjectEntry("success", jsonBool(true)), JsonObjectEntry("sessions", jsonArray(values.toArray()))])
    }
    func finishInvocation(): Unit {
        if (!publishedTerminal) { return }
        // Publication has synchronously consumed the Native response. Drop the
        // entire workflow DOM before refunding its actual response ownership.
        match (workflow) { case Some(value) => value.close(); case None => () }; workflow = None; identity = None
        publishedTerminal = false
        match (active) {
            case Some(value) =>
                if(discardFailedStartup && value.leaseId!="" && text(value.policy.snapshot(),"status")!="terminated"){
                    // An actual approved adapter may still be alive. Keep its
                    // paid Native state truthful and quarantined; rejection
                    // authorizes no compensation close or restart.
                    value.unknown=true
                }else if (discardFailedStartup || text(value.policy.snapshot(), "status") == "terminated") {
                    if (!discardFailedStartup) { history.add(DapOwnedDebugHistory(value.snapshot())) }
                    value.close(); active = None
                }
            case None => ()
        }
        discardFailedStartup = false
    }
    func abort(): Unit {
        match (active) { case Some(value) => value.unknown = true; case None => () }
        match (workflow) { case Some(value) => value.close(); case None => () }; workflow = None; identity = None
    }
    func close(): Unit {
        if (closed) { return }; closed = true; abort()
        match (active) { case Some(value) => value.close(); case None => () }; active = None
        for (value in history) { value.close() }; history.clear()
    }
}
