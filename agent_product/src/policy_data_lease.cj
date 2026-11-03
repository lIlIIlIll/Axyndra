package agent_product

import agent_domain.*
import std.collection.*
import std.sync.*
import yjson.*
import yjson_support.*

// The provider result's decoded value outlives its transport only while this
// explicit query-local lease retains its allocation charge. This carries data,
// never a provider generation, Run, source grant or executable capability.
class ProductPolicyValueLease {
    let value: AgentValue
    private let release: () -> Unit
    private let lock = Mutex()
    private var closed = false
    init(value: AgentValue, release: () -> Unit) { this.value = value; this.release = release }
    func available(): Bool { lock.lock(); try { !closed } finally { lock.unlock() } }
    func close(): Unit {
        lock.lock(); let owned = try { if (closed) { false } else { closed = true; true } } finally { lock.unlock() }
        if (owned) { release() }
    }
}
class ProductPolicyValueRecord {
    let sequence: Int64
    let lease: ProductPolicyValueLease
    init(sequence: Int64, lease: ProductPolicyValueLease) { this.sequence = sequence; this.lease = lease }
}
func productPolicyCopyCost(value: AgentValue, depth!: Int64 = 0): Int64 {
    if (depth > 64) { throw IllegalStateException("policy value nesting exceeds allocation bound") }
    var cost: Int64 = 512
    match (value.unifiedKind) {
        case ValueKind.Text => cost = productPolicyCopyAdd(cost, productPolicyStringCost(value.text))
        case ValueKind.Number => cost = productPolicyCopyAdd(cost, productPolicyStringCost(value.asNumberText()))
        case ValueKind.List =>
            for (child in value.items) { cost = productPolicyCopyAdd(cost, productPolicyCopyCost(child, depth: depth + 1)) }
        case ValueKind.Object =>
            for (field in value.fields) {
                cost = productPolicyCopyAdd(cost, productPolicyStringCost(field.name))
                cost = productPolicyCopyAdd(cost, productPolicyCopyCost(field.value, depth: depth + 1))
            }
        case _ => ()
    }; cost
}
func productPolicyStringCost(value: String): Int64 {
    if (value.size > 134217728 / 8) { throw IllegalStateException("policy value exceeds allocation bound") }
    value.size * 8
}
func productPolicyCopyAdd(left: Int64, right: Int64): Int64 {
    if (left < 0 || right < 0 || right > 134217728 - left) { throw IllegalStateException("policy value exceeds allocation bound") }
    left + right
}

// Final values retain only their own text/provenance; closing the query/source
// owner never releases this charge, and this lease never captures the history.
func retainProductPolicyData(value: AgentValue): ProductPolicyValueLease {
    let owner = ProductPolicyDataReferences("retained-policy-result")
    try {
        let copy = owner.copy(value)
        ProductPolicyValueLease(copy.value, { => copy.close(); owner.close() })
    } catch (error: Exception) { owner.close(); throw error }
}
func retainProductPolicyText(parts: Array<String>): ProductPolicyValueLease {
    let owner = ProductPolicyDataReferences("retained-policy-text")
    try {
        let copy = owner.concatenate(parts)
        ProductPolicyValueLease(copy.value, { => copy.close(); owner.close() })
    } catch (error: Exception) { owner.close(); throw error }
}
