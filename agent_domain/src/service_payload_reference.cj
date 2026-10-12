package agent_domain

import std.convert.*
import yjson.*
import yjson_support.*

public let HOST_CHANNEL_PAYLOAD_INTENT_VERSION = "process-channel-intent-v2"
public let SERVICE_PAYLOAD_REFERENCE_SCHEMA = "axyndra.service-payload/v1"

// Content identity, not a capability. Only Product transforms pure bytes into
// these values. Store rechecks the exact staged witness and artifact metadata;
// the executor verifies actual bytes after canonical execution admission.
public func servicePayloadReferenceBytes(value: AgentValue, maximum: Int64): Result<Int64> {
    if (!httpIntentExactFields(value, ["schema", "artifact_ref", "encoding", "bytes", "sha256", "encoded_sha256"]) ||
        httpIntentText(value, "schema") != SERVICE_PAYLOAD_REFERENCE_SCHEMA || httpIntentText(value, "encoding") != "hex" ||
        !httpIntentDigest(httpIntentText(value, "sha256")) || !httpIntentDigest(httpIntentText(value, "encoded_sha256")) ||
        httpIntentText(value, "artifact_ref") != "blob:sha256:" + httpIntentText(value, "encoded_sha256")) {
        return channelIntentError("channel.payload_reference_invalid", "payload reference has an invalid immutable content identity")
    }
    try {
        let size = value.field("bytes").getOrThrow()
        if (size.unifiedKind != ValueKind.Number) { throw IllegalArgumentException("invalid payload size") }
        let parsed = Int64.parse(size.asNumberText())
        if (maximum < 1 || maximum > 4194304 || parsed < 1 || parsed > maximum || parsed.toString() != size.asNumberText()) {
            throw IllegalArgumentException("payload size exceeds its approved bound")
        }
        Result.Ok(parsed)
    } catch (_: Exception) { channelIntentError("channel.payload_reference_invalid", "payload reference size is not a bounded canonical integer") }
}

public func channelServiceIntentBytes(intent: AgentValue, binding: AgentValue): Result<Int64> {
    if (httpIntentExactFields(intent, ["id", "bytes_hex"])) {
        match (channelServiceWriteBytes(intent, maximumBytes: serviceProtocolLimits(binding).value().getOrThrow().requestBytes)) {
            case Result.Err(error) => Result.Err(error); case Result.Ok(value) => Result.Ok(value.size)
        }
    } else if (httpIntentExactFields(intent, ["id", "payload"]) && httpIntentIdentifier(httpIntentText(intent, "id"))) {
        let limits = match (servicePayloadLimits(binding)) {
            case Result.Ok(Some(value)) => value
            case _ => return channelIntentError("channel.payload_not_granted", "artifact payload requires an exact startup payload profile")
        }
        servicePayloadReferenceBytes(intent.field("payload").getOrThrow(), limits.maxWriteBytes)
    } else { channelIntentError("channel.intent_invalid", "channel intent must contain exactly inline bytes or one host payload reference") }
}

public func servicePayloadPreparationWitness(threadId: String, runId: String, epoch: Int64,
    callId: String, toolName: String, input: AgentValue, binding: AgentValue, intent: AgentValue): AgentValue {
    objectValue([ValueField("schema", textValue("axyndra.service-payload-preparation/v1")),
        ValueField("thread_id", textValue(threadId)), ValueField("run_id", textValue(runId)), ValueField("epoch", integerValue(epoch)),
        ValueField("call_id", textValue(callId)), ValueField("tool_name", textValue(toolName)),
        ValueField("input_digest", textValue(modelPolicySha256Text(canonicalAgentValue(input)))),
        ValueField("binding_digest", textValue(modelPolicySha256Text(canonicalAgentValue(binding)))), ValueField("intent", intent)])
}
