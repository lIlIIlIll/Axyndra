package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

func memoryRequireTotalSegment(rows: Array<AgentValue>, mode: String): Unit {
    if (mode != "semantic") { return }
    for (row in rows) {
        let score = decodeExactFloat64(row.field("semantic").getOrThrow())
        if (score != score) { throw PureProviderError("memory.semantic_partition_required", "unordered scores require original-stream partitioning") }
    }
}

// This is the old insertion algorithm's exact NaN behavior, not a new total
// ordering: a NaN never moves left, and no later row can move across it. The
// intervening non-NaN segments keep the original score/id comparator. Groups
// describe pure ordering work only; none is an identity or retained session.
func memoryPartitionSemanticPage(value: AgentValue): AgentValue {
    memoryPolicyFields(value, ["schema", "action", "snapshot_digest", "page_id", "rows"])
    if (memoryPolicyText(value, "snapshot_digest") == "" || memoryPolicyText(value, "page_id") == "") {
        throw PureProviderError("memory.page_identity", "page requires an exact query witness") }
    let rows = memoryPageRows(value, "rows"); let groups = ArrayList<AgentValue>(); let pending = ArrayList<AgentValue>()
    for (row in rows) {
        let score = decodeExactFloat64(row.field("semantic").getOrThrow())
        if (score != score) {
            if (!pending.isEmpty()) {
                groups.add(objectValue([ValueField("sortable", boolValue(true)), ValueField("rows", listValue(pending.toArray()))])); pending.clear()
            }
            groups.add(objectValue([ValueField("sortable", boolValue(false)), ValueField("rows", listValue([row]))]))
        } else { pending.add(row) }
    }
    if (!pending.isEmpty()) { groups.add(objectValue([ValueField("sortable", boolValue(true)), ValueField("rows", listValue(pending.toArray()))])) }
    memoryPageReply(value, [ValueField("groups", listValue(groups.toArray()))])
}
