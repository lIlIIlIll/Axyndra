package agent_domain

import std.convert.*
import yjson.*
import yjson_support.*

public let PLUGIN_DOCUMENT_PAYLOAD_INTENT_SCHEMA = "axyndra.plugin-document-intent/v2"
public let PLUGIN_DOCUMENT_PAYLOAD_PARENT_SCHEMA = "axyndra.plugin-document-parent/v2"
public let PLUGIN_DOCUMENT_PAYLOAD_RESULT_SCHEMA = "axyndra.plugin-document-result/v2"

public let PLUGIN_DOCUMENT_PAYLOAD_SCHEMA = "axyndra.plugin-document-payload/v1"
public let PLUGIN_DOCUMENT_PAYLOAD_READ_SCHEMA = "axyndra.plugin-document-read/v2"
public let PLUGIN_DOCUMENT_PAYLOAD_READ_RESULT_SCHEMA = "axyndra.plugin-document-read-result/v2"

// Content identity only. No constructor/parser grants access to an artifact,
// document, Run or namespace. A host-created descriptor must also have its
// exact canonical ContextRead/parent witness in the existing Store audit.
public class PluginDocumentPayloadReference {
    public let digest: String
    public let bytes: Int64
    init(digest: String, bytes: Int64) { this.digest = digest; this.bytes = bytes }
    public func value(): AgentValue {
        objectValue([ValueField("schema", textValue(PLUGIN_DOCUMENT_PAYLOAD_SCHEMA)),
            ValueField("artifact_ref", textValue("blob:sha256:" + digest)),
            ValueField("encoding", textValue("utf8")), ValueField("bytes", integerValue(bytes)),
            ValueField("sha256", textValue(digest)),
            ValueField("content_type", textValue("text/plain; charset=utf-8"))])
    }
}

public func parsePluginDocumentPayloadReference(value: AgentValue): Result<PluginDocumentPayloadReference> {
    try {
        if (!httpIntentExactFields(value, ["schema", "artifact_ref", "encoding", "bytes", "sha256", "content_type"]) ||
            httpIntentText(value, "schema") != PLUGIN_DOCUMENT_PAYLOAD_SCHEMA ||
            httpIntentText(value, "encoding") != "utf8" ||
            httpIntentText(value, "content_type") != "text/plain; charset=utf-8" ||
            !httpIntentDigest(httpIntentText(value, "sha256")) ||
            httpIntentText(value, "artifact_ref") != "blob:sha256:" + httpIntentText(value, "sha256")) {
            return pluginDocumentContractError("plugin.document_payload_invalid") }
        let bytes = documentContractInteger(value.field("bytes").getOrThrow())
        if (bytes < 0 || bytes > PLUGIN_DOCUMENT_MAX_BYTES) {
            return pluginDocumentContractError("plugin.document_payload_invalid") }
        Result.Ok(PluginDocumentPayloadReference(httpIntentText(value, "sha256"), bytes))
    } catch (_: Exception) { pluginDocumentContractError("plugin.document_payload_invalid") }
}

public func pluginDocumentPayloadSnapshotValid(value: AgentValue, key: String): Bool {
    try {
        if (!httpIntentExactFields(value, ["key", "revision", "payload"]) ||
            httpIntentText(value, "key") != key || !documentContractIdentifier(key)) { return false }
        let revision = documentContractInteger(value.field("revision").getOrThrow())
        let payload = parsePluginDocumentPayloadReference(value.field("payload").getOrThrow()).value().getOrThrow()
        revision >= 0 && (revision != 0 || (payload.bytes == 4 && payload.digest == modelPolicySha256Text("null")))
    } catch (_: Exception) { false }
}

// Only describes the immutable proposed data. Actual admission requires the
// original Completed ContextRead plus host preparation pins; a plugin-created
// descriptor, existing artifact, or matching hash alone is never sufficient.
func parsePluginDocumentPayloadIntent(value: AgentValue): Result<PluginDocumentIntent> {
    try {
        if (!httpIntentExactFields(value, ["schema", "binding", "intent"]) ||
            httpIntentText(value, "schema") != PLUGIN_DOCUMENT_PAYLOAD_INTENT_SCHEMA) {
            return pluginDocumentContractError("plugin.document_intent_invalid") }
        let binding = value.field("binding").getOrThrow()
        match (validatePluginDocumentBinding(binding)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let raw = value.field("intent").getOrThrow()
        if (!httpIntentExactFields(raw, ["id", "key", "mode", "expected_revision", "expected_payload", "next_payload"]) ||
            !documentContractIdentifier(httpIntentText(raw, "id")) || !documentContractIdentifier(httpIntentText(raw, "key"))) {
            return pluginDocumentContractError("plugin.document_intent_invalid") }
        let revision = documentContractInteger(raw.field("expected_revision").getOrThrow())
        let expected = match (parsePluginDocumentPayloadReference(raw.field("expected_payload").getOrThrow())) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(item) => item }
        if (revision < 0 || (revision == 0 && (expected.bytes != 4 || expected.digest != modelPolicySha256Text("null")))) {
            return pluginDocumentContractError("plugin.document_expected_invalid") }
        let mode = httpIntentText(raw, "mode")
        let next = raw.field("next_payload").getOrThrow()
        var replacement: ?PluginDocumentPayloadReference = None
        if (mode == "read") {
            if (next.unifiedKind != ValueKind.Null) { return pluginDocumentContractError("plugin.document_read_mutation") }
        } else if (mode == "compare_exchange") {
            if (revision == 9223372036854775807) { return pluginDocumentContractError("plugin.document_next_invalid") }
            let item = match (parsePluginDocumentPayloadReference(next)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(item) => item }
            if (item.bytes == 0) { return pluginDocumentContractError("plugin.document_next_invalid") }
            replacement = Some(item)
        } else { return pluginDocumentContractError("plugin.document_mode_invalid") }
        let frozenBinding = encodeAgentValue(binding)
        if (frozenBinding.size > 16384) { return pluginDocumentContractError("plugin.document_binding_invalid") }
        Result.Ok(PluginDocumentIntent(frozenBinding, httpIntentText(raw, "id"), httpIntentText(raw, "key"),
            mode == "compare_exchange", revision, "", expected.digest, None,
            expectedPayload: Some(expected), nextPayload: replacement))
    } catch (_: Exception) { pluginDocumentContractError("plugin.document_intent_invalid") }
}
