package pure_provider_runtime

import logical_json_payload.*
import std.collection.*
import std.convert.*
import std.env.*
import yjson.*
import yjson_support.*

class PureDocumentCancelled <: Exception { init() { super("document invocation cancelled") } }

public class DocumentPolicyToolResult {
    public let value: JsonNode
    public let isError: Bool
    public init(value: JsonNode, isError!: Bool = false) { this.value = value; this.isError = isError }
}

// Not supplied to Provider, preparation or Command handlers. This merely
// emits exact intent IDs; the actual Host alone admits and commits each one.
public class DocumentPolicyBroker {
    private let window: DocumentProtocolWindow
    private let claimed = HashSet<String>()
    // Host reserves sequence 1 for the invocation; its first service response is 2.
    private var sequence: Int64 = 2
    private var failed = false
    init(window: DocumentProtocolWindow) { this.window = window }
    public func consume(intentId: String): JsonNode {
        if (failed || providerText(window.invocation, "kind") != "tool" || intentId == "" ||
            intentId.size > 128 || claimed.size >= 8 || claimed.contains(intentId)) {
            throw PureProviderError("document.intent_reused", "document intents are bounded and single-use") }
        claimed.add(intentId)
        try {
            providerDeadline(window.deadline)
            let fields = providerEnvelope(window.invocation, "service_request")
            fields.add(JsonObjectEntry("request_id", jsonString(intentId)))
            fields.add(JsonObjectEntry("service", jsonString("document.store")))
            fields.add(JsonObjectEntry("arguments", jsonObject([JsonObjectEntry("intent_id", jsonString(intentId))])))
            providerEmit(jsonObject(fields.toArray()))
            let response = window.documentResponse(sequence, intentId)
            sequence++
            response
        } catch (error: Exception) { failed = true; throw error }
    }
    func requireComplete(): Unit {
        if (failed) { throw PureProviderError("document.service_failed", "a failed Host response cannot become success") }
    }
}

func documentProtocolIdentity(frame: JsonNode, hello: JsonNode, contextEnabled!: Bool = false): Bool {
    for (name in ["protocol", "extension_id", "extension_version", "generation"]) {
        if (stringifyUnifiedJson(frame.field(name) ?? jsonNull()) != stringifyUnifiedJson(hello.field(name) ?? jsonNull())) { return false } }
    for (name in ["id", "thread_id", "tool"]) {
        let value = frame.field(name) ?? jsonNull()
        if (value.unifiedKind != UnifiedJsonKind.Text || value.text == "" || value.text.size > 1024 || value.text.contains("\u{0000}")) { return false } }
    let kind = providerText(frame, "kind")
    if (kind == "provider") { return providerValidInvocation(frame, hello) }
    if (kind == "context_provider") {
        if (!contextEnabled) { return false }
        for (name in ["call_id", "run_id", "operation_id", "command_id"]) {
            let value=frame.field(name) ?? jsonNull()
            if (value.unifiedKind != UnifiedJsonKind.Text || value.text.contains("\u{0000}") || value.text.size>1024) { return false }
            if ((name=="call_id") != (value.text!="")) { return false }
        }
        let epoch=frame.field("epoch") ?? jsonNull()
        return epoch.unifiedKind==UnifiedJsonKind.Number && epoch.asNumberText()=="0"
    }
    if (kind == "command") {
        return providerText(frame, "command_id") != "" && providerText(frame, "run_id") == "" &&
            providerText(frame, "operation_id") == "" && providerInteger(frame, "epoch") == 0 }
    if (kind != "prepare" && kind != "tool") { return false }
    if (providerText(frame, "run_id") == "" || providerText(frame, "call_id") == "" ||
        providerText(frame, "command_id") != "" || providerInteger(frame, "epoch") < 1) { return false }
    if (kind == "prepare") { providerText(frame, "operation_id") == "" }
    else { providerText(frame, "operation_id") != "" }
}

func documentProtocolReady(hello: JsonNode, id: String, version: String,
    tools: JsonNode, commands: Array<String>, providers: Array<String>, contexts!: Array<String> = []): Unit {
    if (providerText(hello, "type") != "hello" || providerInteger(hello, "generation") < 1 ||
        providerText(hello, "protocol") != "axyndra-js-host-v2" || providerText(hello, "extension_id") != id ||
        providerText(hello, "extension_version") != version || tools.unifiedKind != UnifiedJsonKind.List || tools.items.isEmpty()) {
        throw PureProviderError("document.identity", "unsupported combined native handshake") }
    let caps = hello.field("capabilities") ?? jsonNull()
    if (caps.unifiedKind != UnifiedJsonKind.List || !caps.items.isEmpty()) {
        throw PureProviderError("document.authority", "combined package accepts no ambient process capability") }
    let content = hello.field("content_payload_limits") ?? jsonNull()
    let ordinary = hello.field("ordinary_tool_payload") ?? jsonNull()
    if ((content.unifiedKind != UnifiedJsonKind.Null && !validContentPayloadLimits(content)) ||
        (ordinary.unifiedKind != UnifiedJsonKind.Null && !validOrdinaryToolPayloadOffer(ordinary))) {
        throw PureProviderError("document.payload_profile", "combined endpoint requires exact compatible payload offers") }
    let sequence = hello.field("policy_sequence") ?? jsonNull()
    if (sequence.unifiedKind != UnifiedJsonKind.Null && (sequence.unifiedKind != UnifiedJsonKind.Text ||
        sequence.text != "provider-invoke-i63-v1" || content.unifiedKind == UnifiedJsonKind.Null || ordinary.unifiedKind != UnifiedJsonKind.Null)) {
        throw PureProviderError("document.sequence_profile", "unsupported pure mixed-package sequence offer") }
    let contextSequence = hello.field("context_sequence") ?? jsonNull()
    if (contextSequence.unifiedKind != UnifiedJsonKind.Null &&
        (contextSequence.unifiedKind != UnifiedJsonKind.Text || contextSequence.text != "context-invoke-i63-v1" ||
         contexts.isEmpty() || content.unifiedKind == UnifiedJsonKind.Null || ordinary.unifiedKind != UnifiedJsonKind.Null ||
         sequence.unifiedKind != UnifiedJsonKind.Null)) {
        throw PureProviderError("document.context_sequence_profile", "context sequence requires its distinct pure content-only connection") }
    let fields = providerEnvelope(hello, "ready")
    if (sequence.unifiedKind != UnifiedJsonKind.Null) { fields.add(JsonObjectEntry("policy_sequence", sequence)) }
    if (contextSequence.unifiedKind != UnifiedJsonKind.Null) { fields.add(JsonObjectEntry("context_sequence", contextSequence)) }
    fields.add(JsonObjectEntry("capabilities", jsonArray([])))
    fields.add(JsonObjectEntry("tools", tools))
    fields.add(JsonObjectEntry("commands", jsonArray(commands.map { name => jsonObject([
        JsonObjectEntry("name", jsonString(name)), JsonObjectEntry("description", jsonString("Pure user command proposal"))]) })))
    fields.add(JsonObjectEntry("hooks", jsonArray([])))
    fields.add(JsonObjectEntry("providers", jsonArray(providers.map { name => jsonObject([
        JsonObjectEntry("name", jsonString(name)), JsonObjectEntry("description", jsonString("Pure policy data")),
        JsonObjectEntry("protocol", jsonString("axyndra.policy-provider/v1"))]) })))
    if (!contexts.isEmpty()) { fields.add(JsonObjectEntry("context_providers", jsonArray(contexts.map { name => jsonObject([
        JsonObjectEntry("name", jsonString(name)), JsonObjectEntry("description", jsonString("Pure observed document content")),
        JsonObjectEntry("protocol", jsonString("axyndra.context-provider/v1"))]) }))) }
    if (content.unifiedKind != UnifiedJsonKind.Null) { fields.add(JsonObjectEntry("content_payload_limits", contentPayloadLimitsValue())) }
    if (ordinary.unifiedKind != UnifiedJsonKind.Null) { fields.add(JsonObjectEntry("ordinary_tool_payload", ordinaryToolPayloadOffer())) }
    providerEmit(jsonObject(fields.toArray()))
}

// New opt-in composition. The existing runPurePolicyProvider contract is not
// changed. The Host still enforces contribution kind, zero Provider services,
// separate scope workers and every canonical source/approval/Receipt.
public func runDocumentPolicyProvider(id: String, version: String, providers: Array<String>, tools: JsonNode,
    commands: Array<String>, policy: (String, JsonNode) -> JsonNode,
    prepare: (String, JsonNode) -> JsonNode,
    execute: (String, JsonNode, DocumentPolicyBroker) -> DocumentPolicyToolResult,
    command: (String, JsonNode) -> JsonNode,
    contextProviders!: Array<String> = [], contextHandler!: ?(String, JsonNode) -> JsonNode = None,
    primitiveTools!: Array<String> = [],
    primitiveExecute!: ?(String, JsonNode, FrozenPrimitiveBroker111) -> DocumentPolicyToolResult = None): Int64 {
    if (getCommandLine().size != 1 || providers.isEmpty() || providers.size > 32 || commands.size > 32 ||
        tools.unifiedKind != UnifiedJsonKind.List || tools.items.isEmpty() || tools.items.size > 32) { return 2 }
    if (contextProviders.size>32 || (!contextProviders.isEmpty() && contextHandler.isNone())) { return 2 }
    let contexts=HashSet<String>()
    for (name in contextProviders) {
        if (!httpIntentIdentifier(name) || contexts.contains(name)) { return 2 }; contexts.add(name)
    }
    if (!primitiveTools.isEmpty() && primitiveExecute.isNone()) { return 2 }
    let primitiveNames = HashSet<String>()
    for (name in primitiveTools) {
        if (!httpIntentIdentifier(name) || primitiveNames.contains(name)) { return 2 }
        var declared = false
        for (tool in tools.items where providerText(tool, "name") == name) { declared = true }
        if (!declared) { return 2 }; primitiveNames.add(name)
    }
    let input = ProviderWireInput()
    try {
        let first = input.next().getOrThrow()
        try {
            let hello = first.value
            documentProtocolReady(hello, id, version, tools, commands, providers, contexts: contextProviders)
            let toolNames = HashSet<String>()
            for (tool in tools.items) {
                let name = providerText(tool, "name")
                if (name == "" || toolNames.contains(name)) { return 2 }; toolNames.add(name) }
            let ids = HashSet<String>()
            var lastSequence: Int64 = 0
            let sequenced = providerText(hello, "policy_sequence") == "provider-invoke-i63-v1"
            let contextSequenced=providerText(hello,"context_sequence")=="context-invoke-i63-v1"
            let contextCounter=DocumentContextSequenceCounter()
            while (true) {
                let incoming = match (input.next()) { case Some(value) => value; case None => return 0 }
                try {
                    let raw = incoming.value
                    if (["shutdown", "close"].contains(providerText(raw, "type"))) { return 0 }
                    if (!["invoke", "payload_begin"].contains(providerText(raw, "type")) || !documentProtocolIdentity(raw, hello, contextEnabled: !contextProviders.isEmpty())) { return 3 }
                    if(contextSequenced){
                        if(providerText(raw,"kind")!="context_provider" || !contextCounter.accept(providerText(raw,"id"))){return 3}
                    } else if (sequenced) {
                        // This connection is pure even though its installed package
                        // declares other contribution kinds. No Tool broker can exist.
                        if (providerText(raw, "kind") != "provider") { return 3 }
                        let id = providerText(raw, "id")
                        if (!id.startsWith("invoke-") || id.size <= 7 || id.size > 26) { return 3 }
                        let serial = try { Int64.parse(id[7..]) } catch (_: Exception) { return 3 }
                        if (serial < 1 || serial >= Int64.Max || serial <= lastSequence || id != "invoke-" + serial.toString()) { return 3 }
                        lastSequence = serial
                    } else {
                        if (ids.size >= 4096 || ids.contains(providerText(raw, "id"))) { return 3 }
                        ids.add(providerText(raw, "id"))
                    }
                    let kind = providerText(raw, "kind"); let name = providerText(raw, "tool")
                    if ((kind == "context_provider" && !contexts.contains(name)) ||
                        (kind == "provider" && !providers.contains(name)) || (kind == "command" && !commands.contains(name)) ||
                        ((kind == "prepare" || kind == "tool") && !toolNames.contains(name))) { return 3 }
                    let window = DocumentProtocolWindow(input, hello, raw)
                    try {
                        let frame = window.invocation
                        if (!documentProtocolIdentity(frame, hello, contextEnabled: !contextProviders.isEmpty())) { return 3 }
                        let args = frame.field("arguments") ?? jsonNull()
                        let charge = providerPayloadBudget.acquire(window.maxResult() + 65536)
                        try {
                            try {
                                providerDeadline(window.deadline)
                                let result: DocumentPolicyToolResult
                                if (kind == "provider") {
                                    if (args.unifiedKind != UnifiedJsonKind.Object || args.fields.size != 2 ||
                                        providerText(args, "schema") != "axyndra.policy-query/v1" || args.field("input").isNone()) {
                                        throw PureProviderError("policy.query_invalid", "expected a pure policy data envelope") }
                                    result = DocumentPolicyToolResult(jsonObject([JsonObjectEntry("schema", jsonString("axyndra.policy-result/v1")),
                                        JsonObjectEntry("value", policy(name, args.field("input").getOrThrow()))]))
                                } else if (kind == "context_provider") {
                                    result = DocumentPolicyToolResult(contextHandler.getOrThrow()(name, args))
                                } else if (kind == "prepare") { result = DocumentPolicyToolResult(prepare(name, args)) }
                                else if (kind == "command") { result = DocumentPolicyToolResult(command(name, args)) }
                                else if (primitiveNames.contains(name)) {
                                    let broker = FrozenPrimitiveBroker111(window)
                                    result = primitiveExecute.getOrThrow()(name, args, broker)
                                    broker.requireComplete()
                                } else {
                                    let broker = DocumentPolicyBroker(window)
                                    result = execute(name, args, broker)
                                    broker.requireComplete()
                                }
                                providerDeadline(window.deadline)
                                let encodedBound=logicalJsonWriteReservationBytes(result.value,window.maxResult())
                                charge.ensureDecoded(encodedBound,logicalJsonValueNodeCount(result.value))
                                let text = stringifyUnifiedJson(result.value)
                                charge.ensureDecoded(text.size, logicalJsonNodeCount(text))
                                window.reply(result.value, !result.isError, charge)
                            } catch (error: PureDocumentCancelled) {
                                providerEmit(jsonObject(providerEnvelope(frame, "cancelled").toArray())); return 0
                            } catch (error: PureProviderError) {
                                window.reply(jsonObject([JsonObjectEntry("code", jsonString(error.code)),
                                    JsonObjectEntry("message", jsonString(error.message))]), false, charge)
                            } catch (_: LogicalJsonPayloadError) {
                                window.reply(jsonObject([JsonObjectEntry("code", jsonString("document.result_capacity")),
                                    JsonObjectEntry("message", jsonString("document result exceeds the original shared allocation bound"))]), false, charge)
                            }
                        } finally { charge.close() }
                    } finally { window.close() }
                } finally { incoming.close() }
            }
            0
        } finally { first.close() }
    } catch (_: Exception) { 3 }
    finally { input.close() }
}
