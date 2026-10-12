package dap_plugin

import std.collection.*
import std.convert.*
import std.sync.*
import yjson.*
import yjson_support.*

// A prepared call keeps only the policy needed at dispatch and response
// observation. The complete request JSON belongs to preparation alone; its
// exact frozen protocol bytes remain owned by DapPreparedRequest/the cache.
class DapFrozenPolicy {
    let breakpointsJson: String
    let stateRevision: Int64
    let contextRevision: Int64
    let usesContext: Bool
    let commands: Array<String>
    init(requests: JsonNode, breakpoints: JsonNode, stateRevision: Int64, contextRevision: Int64, usesContext: Bool) {
        breakpointsJson = stringifyUnifiedJson(breakpoints)
        this.stateRevision = stateRevision; this.contextRevision = contextRevision; this.usesContext = usesContext
        let names = ArrayList<String>()
        for (request in requests.items) { names.add(text(request, "command")) }
        commands = names.toArray()
    }
    func retainedBytes(): Int64 {
        // Include the bounded command strings and metadata, not just the
        // breakpoint JSON. The shared pool also charges retained bytes twice.
        var bytes: Int64 = breakpointsJson.size + 256 + commands.size * 256
        for (command in commands) { bytes += command.size }
        bytes
    }
}
class DapPolicyProjection {
    let requestsJson: String
    let frozen: DapFrozenPolicy
    init(requests: JsonNode, breakpoints: JsonNode, stateRevision: Int64, contextRevision: Int64, usesContext: Bool) {
        requestsJson = stringifyUnifiedJson(requests)
        frozen = DapFrozenPolicy(requests, breakpoints, stateRevision, contextRevision, usesContext)
    }
    func requests(): Array<JsonNode> { parseUnifiedJson(requestsJson, maxBytes: 8388608, maxDepth: 64).items.toArray() }
}

func policyUtf8Tail(value: String, maximum: Int64): String {
    let bytes = value.toArray()
    if (bytes.size <= maximum) { return value }
    var start = bytes.size - maximum
    while (start < bytes.size && bytes[start] >= 128 && bytes[start] < 192) { start++ }
    String.fromUtf8(bytes[start..bytes.size])
}
func policySnapshotText(value: JsonNode, name: String): String {
    let found = text(value, name)
    if (found.size <= 4096) { found } else { "" }
}
func policyCacheBounded(value: String): Bool {
    if (value.size > 262144) { return false }
    try { payloadNodeCount(value) <= 4096 } catch (_: Exception) { false }
}

// A local policy state, never a host grant. Fixed storage shares the endpoint's
// aggregate pool. No callback holding this mutex performs protocol or host I/O.
class DapSessionPolicy {
    private let lock = Mutex()
    private let storage = payloadPool.acquire(3145728, transfer: false)
    private var closed = false
    private var breakpoints = stringifyUnifiedJson(policyBlankBreakpoints())
    private var capabilities = "{}"
    private var debugCapabilitiesJson = "{}"
    private var stateRevision: Int64 = 0
    private var contextRevision: Int64 = 0
    private var debugStopRevision: Int64 = 0
    private var status = "starting"
    private var initialized = false
    private var threadId: Int64 = 0
    private var frameId: Int64 = 0
    private var stopReason = ""
    private var frameName = ""
    private var sourcePath = ""
    private var line: Int64 = 0
    private var column: Int64 = 0
    private var instructionPointer = ""
    private var exitCode: ?Int64 = None
    private var output = ""
    private var outputBytes: Int64 = 0
    private var outputTruncated = false

    func configure(value: JsonNode): Unit {
        let entries = ArrayList<JsonObjectEntry>()
        for (name in ["supportsInstructionBreakpoints", "supportsDataBreakpoints", "supportsDisassembleRequest",
            "supportsReadMemoryRequest", "supportsWriteMemoryRequest", "supportsModulesRequest", "supportsLoadedSourcesRequest"]) {
            entries.add(JsonObjectEntry(name, jsonBool(boolean(value, name))))
        }
        lock.lock(); try { require(!closed); capabilities = stringifyUnifiedJson(jsonObject(entries.toArray())) } finally { lock.unlock() }
    }
    private func contextLocked(): JsonNode {
        jsonObject([JsonObjectEntry("threadId", jsonNumber(threadId.toString())), JsonObjectEntry("frameId", jsonNumber(frameId.toString())),
            JsonObjectEntry("instructionPointerReference", jsonString(instructionPointer))])
    }
    func prepare(action: String, input: JsonNode): DapPolicyProjection {
        // Validate the old raw wrapper first. Aliases only affect its data.
        let original = actionRequests(action, input)
        lock.lock()
        try {
            require(!closed, "dap_plugin.session_closed")
            let projected = parseUnifiedJson(breakpoints, maxBytes: 262144, maxDepth: 32)
            let caps = parseUnifiedJson(capabilities, maxBytes: 4096)
            let requests = ArrayList<JsonNode>(); var usesContext = false
            let first = match (policyItemBreakpoint(action, field(input, "arguments"), projected, caps)) {
                case Some(value) => value
                case None =>
                    let mapped = policyArguments(action, field(input, "arguments"), contextLocked(), caps); usesContext = mapped[1]
                    jsonObject([JsonObjectEntry("command", field(original[0], "command")), JsonObjectEntry("arguments", mapped[0])])
            }
            requests.add(first)
            for (index in 1..original.size) { requests.add(original[index]) }
            for (request in requests) { policyCaptureBreakpoints(projected, request) }
            let encoded = stringifyUnifiedJson(projected)
            // Raw protocol requests can exceed the optional local cache. They
            // are still frozen normally; later item mutations fail explicitly.
            let bounded = if (policyCacheBounded(encoded)) { projected }
                else { policyBlankBreakpoints(known: false) }
            DapPolicyProjection(jsonArray(requests.toArray()), bounded, stateRevision, contextRevision, usesContext)
        } finally { lock.unlock() }
    }
    // The public debug frontend has already applied the former defaults.
    // Map item breakpoint mutations once, but never inject an implicit frame
    // a second time after an explicit frame_id=0 deliberately suppressed it.
    // Projection and context capture occur under the same policy lock.
    func prepareDebug(input: JsonNode, locations: DapDebugLocations,
        launchDefaults: JsonNode, attachDefaults: JsonNode): (DapDebugCall, ?DapPolicyProjection) {
        lock.lock()
        try {
            require(!closed, "dap_plugin.session_closed")
            let caps = parseUnifiedJson(debugCapabilitiesJson, maxBytes: 4096)
            let call = prepareDebugCall(input, contextLocked(), caps, locations, launchDefaults, attachDefaults)
            if (call.request.isNone()) { return (call, None) }
            let projected = parseUnifiedJson(breakpoints, maxBytes: 262144, maxDepth: 32)
            let request = call.request.getOrThrow()
            let first = match (policyItemBreakpoint(call.action, field(request, "arguments"), projected, caps)) {
                case Some(value) => value
                case None => request
            }
            policyCaptureBreakpoints(projected, first)
            let encoded = stringifyUnifiedJson(projected)
            let bounded = if (policyCacheBounded(encoded)) { projected } else { policyBlankBreakpoints(known: false) }
            (call, Some(DapPolicyProjection(jsonArray([first]), bounded, stateRevision, contextRevision, call.usesContext)))
        } finally { lock.unlock() }
    }
    func configureDebug(value: JsonNode): Unit {
        let entries = ArrayList<JsonObjectEntry>()
        for (name in ["supportsInstructionBreakpoints", "supportsDataBreakpoints", "supportsDisassembleRequest",
            "supportsReadMemoryRequest", "supportsWriteMemoryRequest", "supportsModulesRequest", "supportsLoadedSourcesRequest",
            "supportsTerminateRequest", "supportsConfigurationDoneRequest"]) {
            entries.add(JsonObjectEntry(name, jsonBool(boolean(value, name))))
        }
        let encoded = stringifyUnifiedJson(jsonObject(entries.toArray()))
        require(encoded.size <= 4096, "dap_plugin.capability_limit")
        lock.lock(); try { require(!closed); debugCapabilitiesJson = encoded } finally { lock.unlock() }
    }
    func debugOutput(): String {
        lock.lock(); try { require(!closed, "dap_plugin.session_closed"); output } finally { lock.unlock() }
    }
    func debugSupportsConfigurationDone(): Bool {
        lock.lock()
        try { require(!closed); boolean(parseUnifiedJson(debugCapabilitiesJson, maxBytes: 4096), "supportsConfigurationDoneRequest") }
        finally { lock.unlock() }
    }
    func validate(value: DapPolicyProjection): Unit { validate(value.frozen) }
    func validate(value: DapFrozenPolicy): Unit {
        lock.lock()
        try { require(!closed && stateRevision == value.stateRevision && (!value.usesContext || contextRevision == value.contextRevision), "dap_plugin.policy_changed") }
        finally { lock.unlock() }
    }
    func adopt(value: DapPolicyProjection): Int64 { adopt(value.frozen) }
    func adopt(value: DapFrozenPolicy): Int64 {
        lock.lock()
        try {
            require(!closed && stateRevision == value.stateRevision && (!value.usesContext || contextRevision == value.contextRevision), "dap_plugin.policy_changed")
            breakpoints = value.breakpointsJson; stateRevision++
            contextRevision
        } finally { lock.unlock() }
    }
    private func retireFrameLocked(): Unit {
        frameId = 0; frameName = ""; sourcePath = ""; line = 0; column = 0; instructionPointer = ""
    }
    func event(method: String, value: JsonNode): Unit {
        if (value.unifiedKind != UnifiedJsonKind.Object) { return }
        lock.lock()
        try {
            if (closed) { return }
            match (method) {
                case "initialized" => initialized = true; status = "configuring"
                case "stopped" =>
                    status = "stopped"; contextRevision++; debugStopRevision++
                    if (number(value, "threadId") > 0) { threadId = number(value, "threadId") }
                    stopReason = policySnapshotText(value, "reason")
                    // A frame belongs to a particular stop; never implicitly
                    // address an old frame after the next stopped event.
                    retireFrameLocked()
                case "continued" =>
                    status = "running"; contextRevision++
                    if (number(value, "threadId") > 0) { threadId = number(value, "threadId") }
                    retireFrameLocked()
                case "exited" =>
                    status = "exited"; exitCode = Some(policyInteger(value, "exitCode", 0)); contextRevision++; retireFrameLocked()
                case "terminated" => status = "terminated"; contextRevision++; retireFrameLocked()
                case "output" =>
                    let next = text(value, "output")
                    require(next.size <= Int64.Max - outputBytes, "dap_plugin.output_counter_limit")
                    outputBytes += next.size
                    let tail = policyUtf8Tail(next, 131072)
                    if (next.size > tail.size || output.size + tail.size > 131072) { outputTruncated = true }
                    output = policyUtf8Tail(output + tail, 131072)
                case _ => ()
            }
        } finally { lock.unlock() }
    }
    func observeResponses(value: DapPolicyProjection, responses: Array<JsonNode>, dispatchContext: Int64): Unit {
        observeResponses(value.frozen, responses, dispatchContext)
    }
    func observeResponses(value: DapFrozenPolicy, responses: Array<JsonNode>, dispatchContext: Int64): Unit {
        // Do not decode a potentially large prepared request again after its
        // input consumer has finished. At most sixteen bounded command names
        // are retained with the same cached-call allocation.
        require(value.commands.size == responses.size, "dap_plugin.response_count")
        lock.lock()
        try {
            if (closed || contextRevision != dispatchContext) { return }
            for (index in 0..value.commands.size) {
                let command = value.commands[index]; let response = responses[index]
                if (command == "stackTrace") {
                    let frames = field(response, "stackFrames")
                    if (frames.unifiedKind == UnifiedJsonKind.List && !frames.items.isEmpty()) {
                        let top = frames.items[0]
                        if (number(top, "id") > 0) {
                            frameId = number(top, "id"); frameName = policySnapshotText(top, "name")
                            sourcePath = policySnapshotText(field(top, "source"), "path")
                            line = max(0, number(top, "line")); column = max(0, number(top, "column"))
                            instructionPointer = policySnapshotText(top, "instructionPointerReference")
                            contextRevision++
                        }
                    }
                } else if (["continue", "next", "stepIn", "stepOut"].contains(command)) {
                    // A successful resume can replace the continued event.
                    // Previously prepared implicit frame requests and new
                    // requests must both stop using the retired stop context.
                    status = "running"; contextRevision++; retireFrameLocked()
                } else if (command == "terminate" || command == "disconnect") {
                    status = "terminated"; contextRevision++; retireFrameLocked()
                }
            }
        } finally { lock.unlock() }
    }
    func snapshot(): JsonNode {
        lock.lock()
        try {
            let preview = policyUtf8Tail(output, 8192)
            let result = jsonObject([JsonObjectEntry("status", jsonString(status)), JsonObjectEntry("initialized", jsonBool(initialized)),
                JsonObjectEntry("threadId", jsonNumber(threadId.toString())), JsonObjectEntry("frameId", jsonNumber(frameId.toString())),
                JsonObjectEntry("stopReason", jsonString(stopReason)), JsonObjectEntry("frameName", jsonString(frameName)),
                JsonObjectEntry("sourcePath", jsonString(sourcePath)), JsonObjectEntry("line", jsonNumber(line.toString())),
                JsonObjectEntry("column", jsonNumber(column.toString())), JsonObjectEntry("instructionPointerReference", jsonString(instructionPointer)),
                JsonObjectEntry("outputBytes", jsonNumber(outputBytes.toString())), JsonObjectEntry("outputTruncated", jsonBool(outputTruncated)),
                JsonObjectEntry("outputPreview", jsonString(preview)), JsonObjectEntry("outputPreviewTruncated", jsonBool(preview.size < output.size))])
            match (exitCode) { case Some(code) => result.put("exitCode", jsonNumber(code.toString())); case None => () }
            result
        } finally { lock.unlock() }
    }
    func currentDebugStopRevision(): Int64 {
        lock.lock(); try { require(!closed); debugStopRevision } finally { lock.unlock() }
    }
    func debugMarkRunningUnlessStoppedAfter(before: Int64): Unit {
        lock.lock()
        try {
            require(!closed)
            if (debugStopRevision == before && status != "exited" && status != "terminated") {
                status = "running"; contextRevision++; retireFrameLocked()
            }
        } finally { lock.unlock() }
    }
    func debugMarkStarted(): Unit {
        lock.lock()
        try { require(!closed); if (status == "starting" || status == "configuring") { status = "running" } }
        finally { lock.unlock() }
    }
    func debugMarkTerminated(): Unit {
        lock.lock(); try { require(!closed); status = "terminated"; contextRevision++; retireFrameLocked() }
        finally { lock.unlock() }
    }
    func close(): Unit {
        lock.lock()
        try { if (closed) { return }; closed = true; output = ""; breakpoints = "{}"; capabilities = "{}"; debugCapabilitiesJson = "{}" }
        finally { lock.unlock() }
        storage.close()
    }
}
