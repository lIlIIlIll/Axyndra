package pure_provider_runtime

import logical_json_payload.*
import std.collection.*
import std.convert.*
import std.env.*
import yjson.*
import yjson_support.*

public class PureProviderError <: Exception {
    public let code: String
    public init(code: String, message: String) { super(message); this.code = code }
}

let PROVIDER_FRAME_BYTES: Int64 = 262144
let PROVIDER_IDENTITY = ["protocol", "extension_id", "extension_version", "generation", "id", "tool", "kind", "command_id", "thread_id", "run_id", "epoch", "operation_id", "call_id"]

func providerText(value: JsonNode, name: String): String {
    let field = value.field(name) ?? jsonNull()
    if (field.unifiedKind == UnifiedJsonKind.Text) { field.text } else { "" }
}
func providerInteger(value: JsonNode, name: String): Int64 {
    try { Int64.parse(value.field(name).getOrThrow().asNumberText()) } catch (_: Exception) { -1 }
}
func providerEnvelope(source: JsonNode, kind: String): ArrayList<JsonObjectEntry> {
    let fields = ArrayList<JsonObjectEntry>([JsonObjectEntry("type", jsonString(kind))])
    for (name in PROVIDER_IDENTITY) {
        match (source.field(name)) { case Some(value) => fields.add(JsonObjectEntry(name, value)); case None => () } }
    fields
}
func providerEmit(value: JsonNode): Unit {
    let encoded = stringifyUnifiedJson(value)
    if (encoded.size > PROVIDER_FRAME_BYTES) { throw PureProviderError("policy.frame_limit", "frame exceeds its physical bound") }
    let output = getStdOut(); output.write((encoded + "\n").toArray()); output.flush()
}
func providerReady(hello: JsonNode, id: String, version: String, names: Array<String>): Bool {
    if (providerInteger(hello, "generation") < 1 || providerText(hello, "protocol") != "axyndra-js-host-v2" ||
        providerText(hello, "extension_id") != id || providerText(hello, "extension_version") != version) {
        throw PureProviderError("policy.identity", "unsupported handshake") }
    let caps = hello.field("capabilities") ?? jsonNull()
    if (caps.unifiedKind != UnifiedJsonKind.List || !caps.items.isEmpty()) {
        throw PureProviderError("policy.authority", "pure providers do not accept execution capabilities") }
    let offered = hello.field("content_payload_limits") ?? jsonNull()
    let enabled = offered.unifiedKind != UnifiedJsonKind.Null
    if (enabled && !validContentPayloadLimits(offered)) { throw PureProviderError("policy.payload_profile", "unsupported content profile") }
    let sequence = hello.field("policy_sequence") ?? jsonNull()
    if (sequence.unifiedKind != UnifiedJsonKind.Null &&
        (!enabled || sequence.unifiedKind != UnifiedJsonKind.Text || sequence.text != "invoke-i63-v1")) {
        throw PureProviderError("policy.sequence_profile", "unsupported pure host sequence") }
    let fields = providerEnvelope(hello, "ready")
    if (sequence.unifiedKind != UnifiedJsonKind.Null) { fields.add(JsonObjectEntry("policy_sequence", sequence)) }
    if (enabled) { fields.add(JsonObjectEntry("content_payload_limits", contentPayloadLimitsValue())) }
    fields.add(JsonObjectEntry("capabilities", jsonArray([])))
    fields.add(JsonObjectEntry("tools", jsonArray([])))
    fields.add(JsonObjectEntry("commands", jsonArray([])))
    fields.add(JsonObjectEntry("hooks", jsonArray([])))
    fields.add(JsonObjectEntry("providers", jsonArray(names.map { name => jsonObject([
        JsonObjectEntry("name", jsonString(name)), JsonObjectEntry("description", jsonString("Pure policy data")),
        JsonObjectEntry("protocol", jsonString("axyndra.policy-provider/v1"))]) })))
    providerEmit(jsonObject(fields.toArray()))
    enabled
}
func providerValidInvocation(frame: JsonNode, hello: JsonNode): Bool {
    for (name in ["protocol", "extension_id", "extension_version", "generation"]) {
        if (stringifyUnifiedJson(frame.field(name) ?? jsonNull()) != stringifyUnifiedJson(hello.field(name) ?? jsonNull())) { return false } }
    for (name in ["id", "thread_id", "call_id", "tool"]) {
        let value = frame.field(name) ?? jsonNull()
        if (value.unifiedKind != UnifiedJsonKind.Text || value.text == "" || value.text.size > 1024 || value.text.contains("\u{0000}")) { return false } }
    for (name in ["run_id", "operation_id", "command_id"]) {
        let value = frame.field(name) ?? jsonNull()
        if (value.unifiedKind != UnifiedJsonKind.Text || value.text != "") { return false } }
    providerInteger(frame, "epoch") == 0 && providerText(frame, "kind") == "provider"
}

// One bounded native loop. A handler receives data and can propose data only;
// this library contains no broker call, model dispatch or Host state writer.
public func runPurePolicyProvider(id: String, version: String, providers: Array<String>,
    handler: (String, JsonNode) -> JsonNode): Int64 {
    if (getCommandLine().size != 1 || providers.isEmpty() || providers.size > 32) { return 2 }
    let names = providers.clone()
    let unique = HashSet<String>()
    for (name in names) {
        if (name == "" || name.size > 128 || name.contains("\u{0000}") || unique.contains(name)) { return 2 }
        unique.add(name)
    }
    let input = ProviderWireInput()
    try {
        var hello: ?JsonNode = None
        var payloadEnabled = false
        let ids = HashSet<String>()
        var lastSequence: Int64 = 0
        while (true) {
            let incoming = match (input.next()) { case Some(value) => value; case None => return 0 }
            try {
                let frame = incoming.value
                match (providerText(frame, "type")) {
                    case "hello" =>
                        if (hello.isSome()) { return 3 }
                        payloadEnabled = providerReady(frame, id, version, names); hello = Some(frame)
                    case "invoke" | "payload_begin" =>
                        if (hello.isNone() || !providerValidInvocation(frame, hello.getOrThrow()) ||
                            !unique.contains(providerText(frame, "tool"))) { return 3 }
                        if (providerText(hello.getOrThrow(), "policy_sequence") == "invoke-i63-v1") {
                            // The actual host allocates invoke-N while holding
                            // its single-worker state lock. The full immutable
                            // handshake identity is checked above, including generation.
                            let name = providerText(frame, "id")
                            if (!name.startsWith("invoke-") || name.size <= 7 || name.size > 26) { return 3 }
                            let sequence = try { Int64.parse(name[7..]) } catch (_: Exception) { return 3 }
                            if (sequence < 1 || sequence >= Int64.Max || sequence <= lastSequence ||
                                name != "invoke-" + sequence.toString()) { return 3 }
                            // Claim before receiving payload/calling user code;
                            // a malformed, cancelled or failed query cannot replay.
                            lastSequence = sequence
                        } else {
                            if (ids.size >= 4096 || ids.contains(providerText(frame, "id"))) { return 3 }
                            ids.add(providerText(frame, "id"))
                        }
                        let selected = providerReceiveQuery(frame, hello.getOrThrow(), payloadEnabled, input)
                        try {
                            let query = selected.value.field("arguments") ?? jsonNull()
                            let queryLimit = if (payloadEnabled) { CONTENT_PAYLOAD_INPUT_BYTES } else { 65536 }
                            let resultLimit = if (payloadEnabled) { CONTENT_PAYLOAD_RESULT_BYTES } else { 196608 }
                            let charge = providerPayloadBudget.acquire(resultLimit + 65536)
                            try {
                                try {
                                    providerDeadline(selected.deadline)
                                    if (query.unifiedKind != UnifiedJsonKind.Object || query.fields.size != 2 ||
                                        providerText(query, "schema") != "axyndra.policy-query/v1" || query.field("input").isNone() ||
                                        stringifyUnifiedJson(query).size > queryLimit) {
                                        throw PureProviderError("policy.query_invalid", "expected a bounded pure policy input envelope") }
                                    let value = handler(providerText(frame, "tool"), query.field("input").getOrThrow())
                                    let result = jsonObject([JsonObjectEntry("schema", jsonString("axyndra.policy-result/v1")),
                                        JsonObjectEntry("value", value)])
                                    let encoded = stringifyUnifiedJson(result)
                                    if (encoded.size > resultLimit) { throw PureProviderError("policy.result_limit", "policy proposal exceeds its finite bound") }
                                    charge.ensureDecoded(encoded.size, logicalJsonNodeCount(encoded))
                                    providerPayloadReply(selected.value, result, true, payloadEnabled, selected.deadline)
                                } catch (error: PureProviderError) {
                                    providerPayloadReply(selected.value, jsonObject([JsonObjectEntry("code", jsonString(error.code))]),
                                        false, payloadEnabled, selected.deadline)
                                }
                            } finally { charge.close() }
                        } finally { selected.close() }
                    case "shutdown" | "close" => return 0
                    case _ => return 3
                }
            } finally { incoming.close() }
        }
        0
    } catch (_: Exception) { 3 }
    finally { input.close() }
}
