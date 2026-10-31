package native_model_providers

import agent_domain.*
import model_provider_runtime.*
import std.collection.*
import std.io.*
import std.env.*
import yjson.*
import yjson_support.*

func rawWrite(value: AgentValue): Unit {
    let encoded = value.stringify(); need(encoded.size <= MODEL_NATIVE_FRAME)
    getStdOut().write((encoded + "\n").toArray()); getStdOut().flush()
}

func bootstrap(hello: AgentValue, input: ModelInput): Int64 {
    need(txt(hello, "type") == "hello" && txt(hello, "protocol") == "axyndra-js-host-v2" &&
        txt(hello, "extension_id") == "model-providers" && txt(hello, "extension_version") == "1.2.0" && num(hello, "generation") > 0)
    let fields = ArrayList<ValueField>([ValueField("type", textValue("ready"))])
    for (name in ["protocol", "extension_id", "extension_version", "generation", "id", "tool", "kind",
        "command_id", "thread_id", "run_id", "epoch", "operation_id", "call_id"]) {
        match (hello.field(name)) { case Some(value) => fields.add(ValueField(name, value)); case None => () }
    }
    fields.add(ValueField("capabilities", field(hello, "capabilities")))
    for (name in ["tools", "commands", "hooks", "services"]) { fields.add(ValueField(name, listValue([]))) }
    fields.add(ValueField("model_providers", listValue(MODEL_CONTRIBUTIONS.map { name => objectValue([
        ValueField("name", textValue(name)), ValueField("description", textValue("Typed " + name + " ModelProvider")),
        ValueField("protocol", textValue(MODEL_WIRE_SCHEMA))]) })))
    rawWrite(objectValue(fields.toArray()))
    // Discovery is powerless and has no model/Tool/Service execution route.
    // The host terminates this isolated bootstrap process after inspection.
    if (input.read().isSome()) { return 3 }
    0
}

func executeModel(hello: AgentValue, input: ModelInput): Int64 {
    let limits: ?ServicePayloadLimits = match (hello.field("payload_limits")) {
        case None => None
        case Some(value) => match (parseServicePayloadLimits(value)) {
            case Result.Ok(profile) => Some(profile)
            case Result.Err(_) => throw ModelWireFailure("model.payload_profile_invalid")
        }
    }
    exact(hello, if (limits.isSome()) { ["schema", "type", "binding_digest", "identity", "payload_limits", "payload_window"] }
        else { ["schema", "type", "binding_digest"] })
    need(txt(hello, "schema") == MODEL_WIRE_SCHEMA && txt(hello, "type") == "hello")
    let digest = txt(hello, "binding_digest"); need(digest.size == 64)
    let fields = ArrayList<ValueField>([ValueField("schema", textValue(MODEL_WIRE_SCHEMA)), ValueField("type", textValue("ready")),
        ValueField("binding_digest", textValue(digest))])
    input.activate()
    match (limits) { case None => (); case Some(profile) =>
        let identity = field(hello, "identity"); let window = txt(hello, "payload_window")
        need(txt(identity, "binding_digest") == digest && window == "model-" + modelPolicySha256Text(canonicalAgentValue(identity)))
        input.configure(identity, window, profile)
        fields.add(ValueField("payload_limits", profile.toValue()))
        fields.add(ValueField("payload_window", textValue(window)))
    }
    rawWrite(objectValue(fields.toArray()))
    let received = input.readMessage()
    try {
    let frame = received.value
    exact(frame, ["schema", "type", "identity", "binding", "request", "transport_hard_timeout_ms"])
    need(txt(frame, "schema") == MODEL_WIRE_SCHEMA && txt(frame, "type") == "execute")
    let identity = field(frame, "identity")
    exact(identity, ["attempt_id", "run_id", "thread_id", "epoch", "request_id", "binding_digest", "input_digest"])
    for (name in ["attempt_id", "run_id", "thread_id", "request_id"]) {
        let value = txt(identity, name); need(value != "" && value.size <= 256 && !value.contains("\u{0}"))
    }
    need(num(identity, "epoch") > 0 && txt(identity, "binding_digest") == digest)
    let binding = field(frame, "binding")
    need(modelPolicySha256Text(canonicalAgentValue(binding)) == digest)
    let neutral = field(frame, "request")
    need(modelPolicySha256Text(canonicalAgentValue(neutral)) == txt(identity, "input_digest"))
    let config = ModelConfiguration(binding)
    let decoded = match (modelRequestFromSnapshotValue(neutral, txt(identity, "request_id"))) {
        case Result.Ok(value) => value; case Result.Err(_) => throw ModelWireFailure("model.plugin_input_invalid")
    }
    need(decoded.model == txt(binding, "model"))
    let timeout = num(frame, "transport_hard_timeout_ms"); need(timeout >= 0)
    let request = ModelRequest(decoded.model, decoded.messages, system: decoded.system, tools: decoded.tools,
        thinking: decoded.thinking, wireMaxOutputTokens: Some(decoded.wireMaxOutputTokens), resolvedPolicy: decoded.resolvedPolicy,
        streaming: decoded.streaming, parallelToolCalls: decoded.parallelToolCalls, requestId: decoded.requestId,
        serviceTier: decoded.serviceTier, cachePolicy: decoded.cachePolicy, cacheKey: decoded.cacheKey,
        toolChoice: decoded.toolChoice, structuredOutput: decoded.structuredOutput, transportHardTimeoutMillis: timeout)
    let output = ModelOutput(identity, input)
    let transport = BrokerModelTransport(input, output, config.refs)
    try {
    let names = ModelToolNames(request)
    let result = config.adapter(transport).execute(config.profile, config.model, names.request(request), { event =>
        match (names.event(event)) {
            case Some(canonical) => match (modelProviderEventValue(canonical)) {
                case Some(value) => output.event("event", value); case None => () }
            case None => ()
        }
    })
    match (result) {
        case Result.Ok(original) =>
            output.event("usage", modelProviderUsageValue(original.usage))
            let reply = match (names.reply(original)) {
                case Some(value) => value
                case None =>
                    output.event("failure", modelProviderFailureValue(unknownModelToolName(original.usage)))
                    output.done()
                    return 0
            }
            var streamedBytes: Int64 = 0
            for (block in reply.blocks where block.kind == ModelBlockKind.Text || block.kind == ModelBlockKind.Reasoning) {
                streamedBytes += block.text.size
            }
            if (request.streaming && streamedBytes > 65536) {
                output.event("reply_stream", modelProviderStreamReplyValue(reply))
            } else { output.event("reply", modelProviderReplyValue(reply)) }
        case Result.Err(error) => output.event("failure", modelProviderFailureValue(error))
    }
    output.done()
    0
    } finally { transport.closeBudget() }
    } finally { received.close() }
}

main(): Int64 {
    try {
        let input = ModelInput(); let hello = input.read().getOrThrow()
        if (hello.field("protocol").isSome()) { bootstrap(hello, input) }
        else { executeModel(hello, input) }
    } catch (_: Exception) {
        // The boundary does not echo input, stderr, provider diagnostics, or
        // credentials. A poisoned identity produces EOF and no terminal.
        3
    }
}
