package agent_domain

import std.convert.*
import yjson.*
import yjson_support.*

// This observation names an actual resource. It creates no Source, read
// grant, effect authorization or file-content projection. The existing
// canonical read plan validates all common path/classification fields.
public let CONTEXT_READ_PATH_IDENTITY_KIND = "path_identity"

public func contextReadPathIdentityResourceValid(value: AgentValue): Bool {
    if (!httpIntentExactFields(value, ["kind", "source", "path", "witness", "bytes", "permission", "is_directory"]) ||
        httpIntentText(value, "kind") != CONTEXT_READ_PATH_IDENTITY_KIND ||
        value.field("is_directory").getOrThrow().unifiedKind != ValueKind.Boolean ||
        value.field("bytes").getOrThrow().unifiedKind != ValueKind.Number) { return false }
    let count = try { Int64.parse(value.field("bytes").getOrThrow().asNumberText()) } catch (_: Exception) { -1 }
    // bytes measures content returned to the canonical snapshot, never the
    // observed binary file's physical length. No content has been read.
    count == 0 && httpIntentText(value, "witness").startsWith(
        if (value.field("is_directory").getOrThrow().asBool()) { "d:" } else { "f:" })
}
