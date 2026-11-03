package agent_product

import agent_domain.*
import yjson.*
import yjson_support.*

// A bounded neutral preflight before serializing a projection page. Counting
// stops before arithmetic can overflow and never allocates the serialized JSON.
class ProductPolicyJsonBound {
    private var remaining: Int64
    private var nodes: Int64
    init(bytes: Int64, nodes: Int64) { this.remaining = bytes; this.nodes = nodes }
    private func take(amount: Int64): Bool {
        if (amount < 0 || amount > remaining) { return false }
        remaining -= amount; true
    }
    private func text(value: String): Bool {
        if (!take(2)) { return false }
        for (byte in unsafe { value.rawData() }) {
            let size: Int64 = if (byte == 34 || byte == 92 || byte == 8 || byte == 9 || byte == 10 || byte == 12 || byte == 13) { 2 }
                else if (byte < 32) { 6 } else { 1 }
            if (!take(size)) { return false }
        }
        true
    }
    // The caller has already counted an empty array inside its complete
    // envelope. Extend that same counter in order, paying the comma and each
    // child at the array's real depth. Failure ends packing; no failed counter
    // is reused and no JSON text or application policy is created here.
    func appendArrayItem(item: AgentValue, first: Bool, depth: Int64): Bool {
        (!first && !take(1)) == false && value(item, depth: depth)
    }
    func value(item: AgentValue, depth!: Int64 = 0): Bool {
        if (nodes <= 0 || depth > 128) { return false }; nodes--
        match (item.unifiedKind) {
            case ValueKind.Null => take(4)
            case ValueKind.Boolean => take(if (item.asBool()) { 4 } else { 5 })
            case ValueKind.Number => take(item.asNumberText().size)
            case ValueKind.Text => text(item.text)
            case ValueKind.List =>
                if (!take(2)) { return false }; var first = true
                for (child in item.items) {
                    if ((!first && !take(1)) || !value(child, depth: depth + 1)) { return false }; first = false
                }; true
            case ValueKind.Object =>
                if (!take(2)) { return false }; var first = true
                for (field in item.fields) {
                    if ((!first && !take(1)) || !text(field.name) || !take(1) || !value(field.value, depth: depth + 1)) { return false }; first = false
                }; true
        }
    }
}
func productPolicyJsonFits(value: AgentValue, bytes: Int64, nodes: Int64): Bool {
    bytes >= 0 && nodes >= 0 && ProductPolicyJsonBound(bytes, nodes).value(value)
}
