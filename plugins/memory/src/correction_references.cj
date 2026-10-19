package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

func memoryTextNonblankFragment(value: AgentValue): AgentValue {
    memoryPolicyFields(value, ["schema", "action", "snapshot_digest", "page_id", "field_digest", "offset", "total", "text"])
    let offset = memoryPolicyInt(value, "offset"); let total = memoryPolicyInt(value, "total"); let text = memoryPolicyText(value, "text")
    if (offset < 0 || total < offset || text.size > total - offset || text.size > MEMORY_FRAGMENT_BYTES ||
        (text == "" && total > 0)) { memoryFragmentError() }
    memoryPageReply(value, [ValueField("field_digest", value.field("field_digest").getOrThrow()),
        ValueField("next_offset", integerValue(offset + text.size)), ValueField("nonblank", boolValue(text.trimAscii() != ""))])
}

// These references are data selectors into values already owned by the Host,
// not artifact paths, resource locators, or write capabilities. The Host checks
// exact equality with its own references before copying any selected field.
func memoryCorrectionReferences(value: AgentValue): AgentValue {
    memoryPolicyFields(value, ["schema", "action", "snapshot_digest", "page_id", "id", "revision", "status", "current", "changes", "content_nonblank"])
    let permitted = ["kind", "scope", "scope_key", "content", "context", "importance_permille", "expires_at"]
    let current = value.field("current").getOrThrow(); let changes = value.field("changes").getOrThrow()
    memoryPolicyFields(current, permitted)
    if (memoryPolicyText(value, "id") == "" || memoryPolicyInt(value, "revision") < 1 ||
        !["active", "conflicted", "expired"].contains(memoryPolicyText(value, "status")) ||
        changes.unifiedKind != ValueKind.Object || changes.fields.size < 1 || !memoryFragmentBool(value, "content_nonblank")) {
        throw PureProviderError("memory.policy_correction", "memory correction is not applicable") }
    for (field in changes.fields where !permitted.contains(field.name)) {
        throw PureProviderError("memory.policy_correction", "unknown correction field") }
    let fields = ArrayList<ValueField>()
    for (name in permitted) {
        let fromChanges = changes.field(name).isSome()
        let selected = changes.field(name) ?? current.field(name).getOrThrow()
        if (["content", "context", "scope_key"].contains(name)) {
            memoryPolicyFields(selected, ["source", "field", "sha256", "bytes"])
            if (memoryPolicyText(selected, "source") != (if (fromChanges) { "changes" } else { "current" }) ||
                memoryPolicyText(selected, "field") != name || memoryPolicyText(selected, "sha256").size != 64 ||
                memoryPolicyInt(selected, "bytes") < 0) { memoryFragmentError() }
        }
        fields.add(ValueField(name, selected))
    }
    let replacement = objectValue(fields.toArray())
    if (!["preference", "project_fact", "decision", "constraint", "observation"].contains(memoryPolicyText(replacement, "kind")) ||
        !["global", "user", "workspace", "session"].contains(memoryPolicyText(replacement, "scope")) ||
        memoryPolicyInt(replacement, "importance_permille") < 0 || memoryPolicyInt(replacement, "importance_permille") > 1000 ||
        memoryPolicyInt(replacement, "expires_at") < 0) { throw PureProviderError("memory.policy_correction", "invalid replacement data") }
    memoryPageReply(value, [ValueField("id", value.field("id").getOrThrow()), ValueField("revision", value.field("revision").getOrThrow()),
        ValueField("replacement", replacement)])
}
