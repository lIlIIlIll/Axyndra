package web_search_plugin

import std.collection.*
import std.convert.*
import std.env.*
import yjson.*
import yjson_support.*

let WEB_IDENTITY_FIELDS = ["protocol", "extension_id", "extension_version", "generation", "id", "tool", "kind",
    "command_id", "thread_id", "run_id", "epoch", "operation_id", "call_id"]

class WebConfiguration {
    let available: SearchAvailability
    let braveRef: String
    let tavilyRef: String
    init(available: SearchAvailability, braveRef: String, tavilyRef: String) {
        this.available = available; this.braveRef = braveRef; this.tavilyRef = tavilyRef
    }
}

func webExactFields(value: JsonNode, names: Array<String>): Bool {
    if (value.unifiedKind != UnifiedJsonKind.Object || value.fields.size != names.size) { return false }
    for (field in value.fields where !searchContains(names, field.name)) { return false }
    true
}

func webIdentifier(value: String): Bool {
    if (value == "" || value.size > 64) { return false }
    for (byte in value.toArray() where !((byte >= 48u8 && byte <= 57u8) || (byte >= 65u8 && byte <= 90u8) ||
        (byte >= 97u8 && byte <= 122u8) || byte == 45u8 || byte == 95u8 || byte == 46u8)) { return false }
    true
}

func webDigest(value: String): Bool {
    if (value.size != 64) { return false }
    for (byte in value.toArray() where !((byte >= 48u8 && byte <= 57u8) || (byte >= 97u8 && byte <= 102u8))) { return false }
    true
}

func webPackageDigest(value: String): Bool {
    value.startsWith("sha256:") && webDigest(value[7..])
}

func webInstanceGeneration(value: String): Bool {
    try {
        let generation = UInt64.parse(value)
        generation > 0u64 && generation.toString() == value
    } catch (_: Exception) { false }
}

func webConfiguration(value: JsonNode): WebConfiguration {
    if (value.unifiedKind != UnifiedJsonKind.Object) { throw SearchFailure("web_search.configuration_invalid", "configuration must be an object") }
    for (field in value.fields) {
        if (!searchContains(["brave_credential_ref", "tavily_credential_ref", "searxng_url"], field.name) ||
            field.value.unifiedKind != UnifiedJsonKind.Text) {
            throw SearchFailure("web_search.configuration_invalid", "unknown or incorrectly typed configuration field")
        }
        if (field.name == "searxng_url") {
            if (field.value.text.size > 4096 || field.value.text.contains("\u{0000}")) {
                throw SearchFailure("web_search.configuration_invalid", "SearXNG endpoint is oversized or NUL-containing")
            }
        } else if (!webIdentifier(field.value.text)) {
            throw SearchFailure("web_search.configuration_invalid", "credential references must be opaque bounded identifiers")
        }
    }
    let brave = searchText(value, "brave_credential_ref")
    let tavily = searchText(value, "tavily_credential_ref")
    WebConfiguration(SearchAvailability(brave: brave != "", tavily: tavily != "", searxEndpoint: searchText(value, "searxng_url")), brave, tavily)
}

func webFieldObject(fields: Array<SearchField>): JsonNode {
    let entries = ArrayList<JsonObjectEntry>()
    for (field in fields) { entries.add(JsonObjectEntry(field.name, jsonString(field.value))) }
    jsonObject(entries.toArray())
}

func webIntentRequest(request: SearchRequest, config: WebConfiguration): JsonNode {
    let refs = ArrayList<JsonNode>()
    if (request.provider == "brave") { refs.add(jsonString(config.braveRef)) }
    if (request.provider == "tavily") { refs.add(jsonString(config.tavilyRef)) }
    // Credential injection locations are operator-owned host configuration.
    // The plugin sends opaque references, never headers containing key values.
    jsonObject([
        JsonObjectEntry("method", jsonString(request.method)), JsonObjectEntry("url", jsonString(request.url)),
        JsonObjectEntry("query", webFieldObject(request.query)), JsonObjectEntry("headers", webFieldObject(request.headers)),
        JsonObjectEntry("json_body", request.jsonBody ?? jsonNull()), JsonObjectEntry("credential_refs", jsonArray(refs.toArray())),
        JsonObjectEntry("timeout_ms", jsonNumber("120000"))
    ])
}

func webIntents(plan: SearchPlan, config: WebConfiguration): JsonNode {
    match (plan) {
        case SearchPlan.Immediate(_) => jsonArray([])
        case SearchPlan.Request(request) => jsonArray([jsonObject([
            JsonObjectEntry("id", jsonString("search")), JsonObjectEntry("request", webIntentRequest(request, config))
        ])])
    }
}

func webJsonEqual(left: JsonNode, right: JsonNode): Bool {
    if (left.unifiedKind != right.unifiedKind) { return false }
    if (left.unifiedKind == UnifiedJsonKind.Object) {
        if (left.fields.size != right.fields.size) { return false }
        for (field in left.fields) {
            match (right.field(field.name)) { case Some(value) => if (!webJsonEqual(field.value, value)) { return false }; case None => return false }
        }
        return true
    }
    if (left.unifiedKind == UnifiedJsonKind.List) {
        if (left.items.size != right.items.size) { return false }
        for (index in 0..left.items.size) { if (!webJsonEqual(left.items[index], right.items[index])) { return false } }
        return true
    }
    stringifyUnifiedJson(left) == stringifyUnifiedJson(right)
}

func webNumber(value: JsonNode, name: String): Int64 {
    match (value.field(name)) {
        case Some(field) => if (field.unifiedKind == UnifiedJsonKind.Number) {
            try { Int64.parse(field.asNumberText()) } catch (_: Exception) { -1 }
        } else { -1 }
        case None => -1
    }
}

func webBool(value: JsonNode, name: String): Bool {
    match (value.field(name)) { case Some(field) => field.unifiedKind == UnifiedJsonKind.Boolean && field.asBool(); case None => false }
}

func webEnvelope(source: JsonNode, kind: String): ArrayList<JsonObjectEntry> {
    let fields = ArrayList<JsonObjectEntry>([JsonObjectEntry("type", jsonString(kind))])
    for (name in WEB_IDENTITY_FIELDS) {
        match (source.field(name)) { case Some(value) => fields.add(JsonObjectEntry(name, value)); case None => () }
    }
    fields
}

func webSameIdentity(left: JsonNode, right: JsonNode): Bool {
    for (name in WEB_IDENTITY_FIELDS) {
        if (!webJsonEqual(left.field(name) ?? jsonNull(), right.field(name) ?? jsonNull())) { return false }
    }
    true
}

func webFailure(code: String, message: String): JsonNode {
    jsonObject([
        JsonObjectEntry("error", jsonString(if (code.size <= 128) { code } else { "web_search.failed" })),
        JsonObjectEntry("message", jsonString(searchTruncateUtf8(message, 4093)))
    ])
}

func webReply(invocation: JsonNode, value: JsonNode, ok: Bool): Unit {
    if (stringifyUnifiedJson(value).size > WEB_RESULT_BYTES) {
        throw SearchFailure("web_search.result_limit", "search result exceeds 64 KiB; narrow the query or result count")
    }
    let fields = webEnvelope(invocation, "result")
    fields.add(JsonObjectEntry("ok", jsonBool(ok)))
    fields.add(JsonObjectEntry("result", value))
    webWriteFrame(jsonObject(fields.toArray()))
}

func webSearchReply(invocation: JsonNode, value: JsonNode): Unit {
    // Keep the legacy business payload, while exposing its failure through the
    // generic Tool protocol so every client can choose the correct exit status.
    let error = value.field("error") ?? jsonNull()
    webReply(invocation, value, error.unifiedKind == UnifiedJsonKind.Null)
}

func webReady(hello: JsonNode): Unit {
    if (searchText(hello, "protocol") != "axyndra-js-host-v2" || searchText(hello, "extension_id") != "web-search" ||
        searchText(hello, "extension_version") != "1.0.0" || webNumber(hello, "generation") <= 0) {
        throw SearchFailure("web_search.protocol_identity", "unsupported host handshake")
    }
    let fields = webEnvelope(hello, "ready")
    fields.add(JsonObjectEntry("capabilities", hello.field("capabilities") ?? jsonArray([])))
    fields.add(JsonObjectEntry("tools", jsonArray([jsonObject([
        JsonObjectEntry("name", jsonString("web_search")), JsonObjectEntry("description", jsonString("Search the web for up-to-date information using a configured provider.")),
        JsonObjectEntry("input_schema", searchSchema())
    ])])))
    fields.add(JsonObjectEntry("commands", jsonArray([jsonObject([
        JsonObjectEntry("name", jsonString("help")), JsonObjectEntry("description", jsonString("Show web search help without network access."))
    ])])))
    fields.add(JsonObjectEntry("hooks", jsonArray([])))
    webWriteFrame(jsonObject(fields.toArray()))
}

func webValidateIdentity(frame: JsonNode, hello: JsonNode): Unit {
    for (name in ["protocol", "extension_id", "extension_version", "generation"]) {
        if (!webJsonEqual(frame.field(name) ?? jsonNull(), hello.field(name) ?? jsonNull())) {
            throw SearchFailure("web_search.protocol_identity", "invocation does not match the initialized generation")
        }
    }
    // The host owns this opaque string (currently "invoke-N"). Do not parse
    // it as a counter: service responses and cancellation echo it verbatim.
    let invocationId = searchText(frame, "id")
    if (invocationId == "" || invocationId.size > 128 || invocationId.contains("\u{0000}") ||
        searchText(frame, "thread_id") == "") {
        throw SearchFailure("web_search.protocol_identity", "invocation identity is incomplete")
    }
    let kind = searchText(frame, "kind")
    if (kind == "command") {
        if (searchText(frame, "command_id") == "" || searchText(frame, "run_id") != "" ||
            searchText(frame, "operation_id") != "" || searchText(frame, "call_id") != "" || webNumber(frame, "epoch") != 0) {
            throw SearchFailure("web_search.protocol_identity", "offline command identity is invalid")
        }
    } else if ((kind != "prepare" && kind != "tool") || webNumber(frame, "epoch") <= 0 ||
        searchText(frame, "run_id") == "" || searchText(frame, "call_id") == "" || searchText(frame, "command_id") != "" ||
        (kind == "prepare" && searchText(frame, "operation_id") != "") || (kind == "tool" && searchText(frame, "operation_id") == "")) {
        throw SearchFailure("web_search.protocol_identity", "prepared tool identity is incomplete")
    }
}

func webValidateHostPlan(host: JsonNode, plan: SearchPlan, config: WebConfiguration): Unit {
    if (!webExactFields(host, ["version", "plugin", "package_digest", "generation", "configuration_digest", "intents"]) ||
        searchText(host, "version") != "http-intents/v1" || searchText(host, "plugin") != "axyndra:web-search" ||
        !webPackageDigest(searchText(host, "package_digest")) || !webDigest(searchText(host, "configuration_digest")) ||
        !webInstanceGeneration(searchText(host, "generation"))) {
        throw SearchFailure("web_search.host_plan_invalid", "canonical host plan identity is invalid")
    }
    let actual = host.field("intents").getOrThrow()
    let expected = webIntents(plan, config)
    if (actual.unifiedKind != UnifiedJsonKind.List || actual.items.size != expected.items.size) {
        throw SearchFailure("web_search.host_plan_invalid", "host plan does not match the prepared search intents")
    }
    for (index in 0..actual.items.size) {
        let intent = actual.items[index]
        if (!webExactFields(intent, ["id", "request", "network"]) || searchText(intent, "id") != "search" ||
            intent.field("network").getOrThrow().unifiedKind != UnifiedJsonKind.Object ||
            !webJsonEqual(intent.field("request").getOrThrow(), expected.items[index].field("request").getOrThrow())) {
            throw SearchFailure("web_search.host_plan_invalid", "host plan request differs from pure preparation")
        }
    }
}

// Returns true only when one HTTP service response is now pending.
func webInvoke(frame: JsonNode): Bool {
    let kind = searchText(frame, "kind")
    let arguments = frame.field("arguments") ?? jsonNull()
    if (kind == "command") {
        if (searchText(frame, "tool") != "help" || !webExactFields(arguments, ["command_args"]) ||
            arguments.field("command_args").getOrThrow().unifiedKind != UnifiedJsonKind.Text ||
            !searchContains(["", "--help", "-h"], searchText(arguments, "command_args").trimAscii())) {
            throw SearchFailure("web_search.command_invalid", "only the offline help command is available")
        }
        webReply(frame, jsonObject([JsonObjectEntry("content", jsonString(searchCommandHelp()))]), true)
        return false
    }
    if (searchText(frame, "tool") != "web_search" || !webExactFields(arguments,
        if (kind == "prepare") { ["input", "configuration"] } else { ["input", "configuration", "host_plan"] })) {
        throw SearchFailure("web_search.arguments_invalid", "invocation must use the prepared input and configuration envelope")
    }
    let raw = arguments.field("input").getOrThrow()
    if (stringifyUnifiedJson(raw).size > WEB_INPUT_BYTES) { throw SearchFailure("web_search.input_limit", "search input exceeds 16 KiB") }
    let input = decodeSearchInput(raw)
    let config = webConfiguration(arguments.field("configuration").getOrThrow())
    let plan = prepareSearch(input, config.available)
    if (kind == "prepare") {
        webReply(frame, jsonObject([JsonObjectEntry("intents", webIntents(plan, config))]), true)
        return false
    }
    // The canonical plan binds the mounted plugin instance. The outer envelope
    // binds this particular worker connection, checked against hello separately.
    // Preparing and executing on different scopes creates different workers.
    webValidateHostPlan(arguments.field("host_plan").getOrThrow(), plan, config)
    match (plan) {
        case SearchPlan.Immediate(value) => webSearchReply(frame, value); false
        case SearchPlan.Request(_) =>
            let fields = webEnvelope(frame, "service_request")
            fields.add(JsonObjectEntry("request_id", jsonString("search")))
            fields.add(JsonObjectEntry("service", jsonString("network.http")))
            fields.add(JsonObjectEntry("arguments", jsonObject([JsonObjectEntry("intent_id", jsonString("search"))])))
            webWriteFrame(jsonObject(fields.toArray()))
            true
    }
}

func webComplete(invocation: JsonNode, response: JsonNode): Unit {
    if (!webBool(response, "ok")) {
        let error = response.field("error") ?? jsonObject([])
        webReply(invocation, webFailure(searchText(error, "code", fallback: "web_search.transport_failed"),
            searchText(error, "message", fallback: "HTTP service failed")), false)
        return
    }
    let result = response.field("result") ?? jsonNull()
    if (searchText(result, "request_id") != "search" || searchText(result, "service") != "network.http" ||
        searchText(result, "receipt_id") == "" || result.field("is_error").isNone() ||
        result.field("is_error").getOrThrow().unifiedKind != UnifiedJsonKind.Boolean) {
        throw SearchFailure("web_search.service_identity", "HTTP service omitted its matching completed receipt")
    }
    let output = result.field("output") ?? jsonNull()
    if (webBool(result, "is_error")) {
        webReply(invocation, webFailure(searchText(output, "error", fallback: "web_search.transport_failed"),
            searchText(output, "message", fallback: "HTTP service failed")), false)
        return
    }
    let status = webNumber(output, "status")
    if (!webExactFields(output, ["status", "body"]) || status < 100 || status > 599 ||
        output.field("body").getOrThrow().unifiedKind != UnifiedJsonKind.Text) {
        throw SearchFailure("web_search.response_invalid", "HTTP service returned an invalid status or body")
    }
    let body = searchText(output, "body")
    if (body.size > WEB_RESULT_BYTES) { throw SearchFailure("web_search.response_limit", "HTTP response exceeds 64 KiB") }
    let arguments = invocation.field("arguments").getOrThrow()
    let input = decodeSearchInput(arguments.field("input").getOrThrow())
    let provider = selectSearchProvider(input, webConfiguration(arguments.field("configuration").getOrThrow()).available)
    let value = if (status >= 300) { searchFailureResult(provider, "provider request failed with HTTP status " + status.toString()) }
        else { decodeSearchResponse(provider, body, input.limit) }
    webSearchReply(invocation, value)
}

func runWebProtocol(): Int64 {
    var hello: ?JsonNode = None
    var pending: ?JsonNode = None
    var last: ?JsonNode = None
    while (true) {
        let line = match (webReadFrame(getStdIn())) { case Some(value) => value; case None => return 0 }
        let frame = parseUnifiedJson(line, maxBytes: WEB_FRAME_BYTES, maxDepth: 32)
        match (searchText(frame, "type")) {
            case "hello" =>
                if (hello.isSome()) { return 3 }
                webReady(frame); hello = Some(frame)
            case "invoke" =>
                if (hello.isNone() || pending.isSome()) { return 3 }
                webValidateIdentity(frame, hello.getOrThrow())
                last = Some(frame)
                try { if (webInvoke(frame)) { pending = Some(frame) } } catch (error: SearchFailure) {
                    webReply(frame, webFailure(error.code, error.message), false)
                }
            case "service_response" =>
                let invocation = match (pending) { case Some(value) => value; case None => return 3 }
                if (!webSameIdentity(invocation, frame) || searchText(frame, "request_id") != "search") { return 3 }
                try { webComplete(invocation, frame) } catch (error: SearchFailure) {
                    webReply(invocation, webFailure(error.code, error.message), false)
                } catch (_: Exception) {
                    webReply(invocation, webFailure("web_search.response_invalid", "HTTP service returned an invalid result"), false)
                }
                pending = None
            case "cancel" =>
                let invocation = match (if (pending.isSome()) { pending } else { last }) { case Some(value) => value; case None => return 3 }
                if (!webSameIdentity(invocation, frame)) { return 3 }
                webWriteFrame(jsonObject(webEnvelope(frame, "cancelled").toArray()))
                pending = None; last = None
            case "shutdown" | "close" => return 0
            case _ => return 3
        }
    }
    0
}
