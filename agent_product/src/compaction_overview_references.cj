package agent_product

import agent_domain.*
import std.collection.*
import yjson.*
import yjson_support.*

func productCompactionOverviewFromReferences(query: ProductCompactionReferenceQuery,
    reply: ModelReply, maxOutputTokens: Int64): AgentValue {
    let fields = ArrayList<AgentValue>()
    for (block in reply.blocks) {
        fields.add(objectValue([ValueField("kind", textValue(match (block.kind) {
            case ModelBlockKind.Text => "text"; case ModelBlockKind.Reasoning => "reasoning"; case _ => "unsupported" })),
            ValueField("text", textValue(block.text))]))
    }
    // Freeze mutable containers and charge retained immutable data before the
    // first consuming query. No provider DTO can replace this reply projection.
    let frozen = query.references.freeze(listValue(fields.toArray()))
    var state = query.query("overview_begin", [ValueField("max_output_tokens", integerValue(maxOutputTokens)),
        ValueField("accepted_output", boolValue(reply.acceptedOutput)), ValueField("stop_reason", textValue(reply.stopReason))])
    for (block in frozen.items) {
        let mark = query.marker(); var retained: ?AgentValue = None
        try {
        let kind = block.field("kind").getOrThrow()
        let plan = query.query("overview_plan", [ValueField("max_output_tokens", integerValue(maxOutputTokens)),
            ValueField("state", state), ValueField("kind", kind)])
        if (!httpIntentExactFields(plan, ["read"]) || plan.field("read").getOrThrow().unifiedKind != ValueKind.Boolean) {
            throw IllegalStateException("invalid overview reduction plan") }
        let reduced = if (plan.field("read").getOrThrow().asBool()) {
            query.reduce(objectValue([ValueField("key", textValue("overview")), ValueField("mode", textValue("overview")),
                ValueField("limit", integerValue(max(64, maxOutputTokens * 4))),
                ValueField("source", query.references.intern(block.field("text").getOrThrow().text))])).field("result").getOrThrow()
        } else { textValue("") }
        let next = query.query("overview_merge", [ValueField("max_output_tokens", integerValue(maxOutputTokens)),
            ValueField("state", state), ValueField("kind", kind), ValueField("reduced", reduced)])
        query.release(state); state = next; retained = Some(next)
        } finally { query.releaseSince(mark, keep: retained) }
    }
    query.query("overview_finish", [ValueField("max_output_tokens", integerValue(maxOutputTokens)), ValueField("state", state)])
}
