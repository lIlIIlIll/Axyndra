package agent_runtime

import agent_domain.*
import std.convert.*
import yjson.*
import yjson_support.*

// Exact original Store field/order/default comparator, consumed only by the
// private Shared snapshot loan. Caller cannot inject an ACK predicate.
func storedCheckpointToolSetMatches185(lane: AgentValue, expected: ToolSetSnapshot): Bool {
    if (storedCheckpoint185Text(lane, "tool_set_id").trimAscii() != expected.id) { return false }
    match (expected.threadId) {
        case Some(id) => if (storedCheckpoint185Text(lane, "tool_set_thread_id") != id.value) { return false }
        case None => if (lane.field("tool_set_thread_id").isSome()) { return false } }
    let tools = lane.field("tools").getOrThrow()
    if (tools.unifiedKind != ValueKind.List || tools.items.size != expected.entries.size) { return false }
    for (at in 0..expected.entries.size) {
        let actual = tools.items[at]; let wanted = expected.entries[at]
        if (storedCheckpoint185Text(actual, "name").trimAscii() != wanted.name || storedCheckpoint185Text(actual, "description") != wanted.description ||
            storedCheckpoint185Text(actual, "executor_version").trimAscii() != wanted.executorVersion ||
            storedCheckpoint185OptionalText(actual, "implementation_fingerprint").trimAscii() != wanted.implementationFingerprint ||
            storedCheckpoint185OptionalText(actual, "schema_digest") != wanted.schemaDigest ||
            storedCheckpoint185OptionalBool(actual, "available_at_snapshot") != wanted.availableAtSnapshot ||
            !canonicalAgentValuesEqual(actual.field("input_schema").getOrThrow(), wanted.inputSchema)) { return false }
        let caps = actual.field("capabilities").getOrThrow()
        if (caps.unifiedKind != ValueKind.List || caps.items.size != wanted.requiredCapabilities.size) { return false }
        for (index in 0..wanted.requiredCapabilities.size) {
            if (storedCheckpoint185Text(caps.items[index], "kind") != storedCheckpoint185CapabilityName(wanted.requiredCapabilities[index].kind) ||
                storedCheckpoint185Text(caps.items[index], "resource") != wanted.requiredCapabilities[index].resource) { return false } }
    }
    match (lane.field("hooks")) {
        case None => if (!expected.hookHandlers.isEmpty()) { return false }
        case Some(hooks) =>
            if (hooks.unifiedKind != ValueKind.List || hooks.items.size != expected.hookHandlers.size) { return false }
            for (at in 0..expected.hookHandlers.size) {
                let actual = hooks.items[at]; let wanted = expected.hookHandlers[at]
                if (storedCheckpoint185Text(actual, "event") != wanted.event ||
                    storedCheckpoint185Text(actual, "plugin_id").trimAscii() != wanted.pluginId ||
                    storedCheckpoint185Text(actual, "plugin_version").trimAscii() != wanted.pluginVersion ||
                    storedCheckpoint185Text(actual, "content_digest").trimAscii() != wanted.contentDigest ||
                    storedCheckpoint185Text(actual, "package_root").trimAscii() != wanted.packageRoot ||
                    storedCheckpoint185Text(actual, "matcher").trimAscii() != wanted.matcher ||
                    storedCheckpoint185Text(actual, "command") != wanted.command ||
                    storedCheckpoint185Integer(actual, "timeout_millis") != wanted.timeoutMillis) { return false } }
    }
    true
}
private func storedCheckpoint185OptionalText(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case None => ""
        case Some(item) => if (item.unifiedKind == ValueKind.Text) { item.text }
            else { throw IllegalStateException("frozen tool text field changed kind") } }
}
private func storedCheckpoint185Text(value: AgentValue, name: String): String {
    let item = value.field(name).getOrThrow()
    if (item.unifiedKind != ValueKind.Text) { throw IllegalStateException("frozen snapshot text field changed kind") }
    item.text
}
private func storedCheckpoint185Integer(value: AgentValue, name: String): Int64 {
    let item = value.field(name).getOrThrow()
    if (item.unifiedKind != ValueKind.Number) { throw IllegalStateException("frozen snapshot integer field changed kind") }
    Int64.parse(item.asNumberText())
}
private func storedCheckpoint185OptionalBool(value: AgentValue, name: String): Bool {
    match (value.field(name)) {
        case None => true
        case Some(item) => if (item.unifiedKind == ValueKind.Boolean) { item.asBool() }
            else { throw IllegalStateException("frozen tool bool field changed kind") } }
}
private func storedCheckpoint185CapabilityName(kind: CapabilityKind): String {
    match (kind) {
        case CapabilityKind.WorkspaceRead => "workspace_read"; case CapabilityKind.WorkspaceWrite => "workspace_write"
        case CapabilityKind.ProcessSpawn => "process_spawn"; case CapabilityKind.NetworkAccess => "network_access"
        case CapabilityKind.PeerMessage => "peer_message"; case CapabilityKind.Delegate => "delegate"
        case CapabilityKind.ExtensionInvoke => "extension_invoke" }
}

