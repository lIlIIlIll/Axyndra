package agent_domain

import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

public let TOOL_INPUT_ATTACHMENT_SCHEMA = "axyndra.tool-input-attachment/v1"
public let TOOL_INPUT_ATTACHMENT_MAX_BYTES: Int64 = 262144

// A literal top-level field selector. It has no JSON-pointer/path semantics,
// does not name an existing artifact, and conveys no Source or read grant.
public func toolInputAttachmentFieldValid(field: String): Bool {
    if (field == "" || field.size > 64) { return false }
    let bytes = field.toArray()
    for (index in 0..bytes.size) {
        let byte = bytes[index]
        if (!((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
            byte == b'_' || (index > 0 && byte >= b'0' && byte <= b'9'))) { return false }
    }
    field != "host_plan" && field != CONTEXT_READ_INPUT_FIELD
}

public func toolInputAttachmentProfileValid(value: AgentValue): Bool {
    if (!httpIntentExactFields(value, ["field", "max_bytes"]) ||
        !toolInputAttachmentFieldValid(httpIntentText(value, "field"))) { return false }
    let limit = value.field("max_bytes").getOrThrow()
    if (limit.unifiedKind != ValueKind.Number) { return false }
    try {
        let bytes = Int64.parse(limit.asNumberText())
        bytes >= 1 && bytes <= TOOL_INPUT_ATTACHMENT_MAX_BYTES && bytes.toString() == limit.asNumberText()
    } catch (_: Exception) { false }
}

public func validToolInputAttachmentGrants(value: AgentValue): Bool {
    if (value.unifiedKind != ValueKind.List || value.items.size > 16) { return false }
    let seen = HashSet<String>()
    for (grant in value.items) {
        if (!httpIntentExactFields(grant, ["contribution", "field", "max_bytes"]) ||
            !channelIntentIdentifier(httpIntentText(grant, "contribution")) ||
            seen.contains(httpIntentText(grant, "contribution")) ||
            !toolInputAttachmentProfileValid(objectValue([ValueField("field", grant.field("field").getOrThrow()),
                ValueField("max_bytes", grant.field("max_bytes").getOrThrow())]))) { return false }
        seen.add(httpIntentText(grant, "contribution"))
    }
    true
}

public func toolInputAttachmentProfileFromGrant(grant: AgentValue): AgentValue {
    objectValue([ValueField("field", grant.field("field").getOrThrow()),
        ValueField("max_bytes", grant.field("max_bytes").getOrThrow())])
}

// The Host sends descriptive evidence for its actual immutable file. This
// schema never reconstructs a live owner, Source, approval or execution grant.
public func toolInputAttachmentEvidenceValid(value: AgentValue): Bool {
    if (!httpIntentExactFields(value, ["schema", "profile", "artifact", "thread_id", "run_id", "epoch",
        "operation_id", "call_id", "namespace", "package_digest", "generation", "configuration_digest",
        "reserved_receipt_id"]) || httpIntentText(value, "schema") != TOOL_INPUT_ATTACHMENT_SCHEMA ||
        !toolInputAttachmentProfileValid(value.field("profile").getOrThrow()) ||
        !httpServicePluginNamespace(httpIntentText(value, "namespace")) ||
        !httpServicePackageDigest(httpIntentText(value, "package_digest")) ||
        !httpIntentDigest(httpIntentText(value, "configuration_digest"))) { return false }
    for (field in ["thread_id", "run_id", "operation_id", "call_id", "reserved_receipt_id"]) {
        if (httpIntentText(value, field) == "" || httpIntentText(value, field).size > 1024) { return false }
    }
    let epoch = value.field("epoch").getOrThrow()
    if (epoch.unifiedKind != ValueKind.Number) { return false }
    try {
        let actualEpoch = Int64.parse(epoch.asNumberText())
        let generation = UInt64.parse(httpIntentText(value, "generation"))
        if (actualEpoch < 1 || actualEpoch.toString() != epoch.asNumberText() || generation == 0u64 ||
            generation.toString() != httpIntentText(value, "generation")) { return false }
    } catch (_: Exception) { return false }
    let artifact = value.field("artifact").getOrThrow()
    if (!httpIntentExactFields(artifact, ["ref", "sha256", "bytes", "content_type"]) ||
        !httpIntentDigest(httpIntentText(artifact, "sha256")) ||
        httpIntentText(artifact, "ref") != "blob:sha256:" + httpIntentText(artifact, "sha256") ||
        httpIntentText(artifact, "content_type") != "text/plain; charset=utf-8") { return false }
    let count = artifact.field("bytes").getOrThrow()
    if (count.unifiedKind != ValueKind.Number) { return false }
    try {
        let bytes = Int64.parse(count.asNumberText())
        bytes >= 0 && bytes <= readonlyDelegationInteger(value.field("profile").getOrThrow(), "max_bytes") &&
            bytes.toString() == count.asNumberText()
    } catch (_: Exception) { false }
}
