package agent_domain

import yjson.*
import yjson_support.*

// Exact equivalence of the complete original canonicalAgentValue grammar.
// Every raw scalar and ordered child participates. This data-only comparison
// does not replace or release any frozen request, durable witness or grant.
public func canonicalAgentValuesEqual(left: AgentValue, right: AgentValue): Bool {
    if (left.kind() != right.kind()) { return false }
    match (left.kind()) {
        case JsonKind.Null => true
        case JsonKind.Boolean => left.asBool() == right.asBool()
        case JsonKind.Number => left.asNumberText() == right.asNumberText()
        case JsonKind.String => left.asString() == right.asString()
        case JsonKind.Array =>
            let leftArray = left.asArray(); let rightArray = right.asArray()
            if (leftArray.size() != rightArray.size()) { return false }
            for (index in 0..leftArray.size()) {
                if (!canonicalAgentValuesEqual(leftArray.get(index).getOrThrow(),
                    rightArray.get(index).getOrThrow())) { return false }
            }
            true
        case JsonKind.Object =>
            let leftObject = left.asObject(); let rightObject = right.asObject()
            if (leftObject.size() != rightObject.size()) { return false }
            var leftPrevious: Int64 = -1; var rightPrevious: Int64 = -1
            for (_ in 0..leftObject.size()) {
                // Preserve the original stable (name,index) ordering, including
                // duplicate names. No whole fields array or canonical String.
                var leftSelected: Int64 = -1; var rightSelected: Int64 = -1
                for (index in 0..leftObject.size()) {
                    let afterPrevious = leftPrevious < 0 || leftObject.nameAt(index) > leftObject.nameAt(leftPrevious) ||
                        (leftObject.nameAt(index) == leftObject.nameAt(leftPrevious) && index > leftPrevious)
                    if (afterPrevious && (leftSelected < 0 || leftObject.nameAt(index) < leftObject.nameAt(leftSelected) ||
                        (leftObject.nameAt(index) == leftObject.nameAt(leftSelected) && index < leftSelected))) { leftSelected = index }
                }
                for (index in 0..rightObject.size()) {
                    let afterPrevious = rightPrevious < 0 || rightObject.nameAt(index) > rightObject.nameAt(rightPrevious) ||
                        (rightObject.nameAt(index) == rightObject.nameAt(rightPrevious) && index > rightPrevious)
                    if (afterPrevious && (rightSelected < 0 || rightObject.nameAt(index) < rightObject.nameAt(rightSelected) ||
                        (rightObject.nameAt(index) == rightObject.nameAt(rightSelected) && index < rightSelected))) { rightSelected = index }
                }
                if (leftSelected < 0 || rightSelected < 0) {
                    throw IllegalStateException("canonical model object changed during comparison")
                }
                if (leftObject.nameAt(leftSelected) != rightObject.nameAt(rightSelected) ||
                    !canonicalAgentValuesEqual(leftObject.valueAt(leftSelected), rightObject.valueAt(rightSelected))) { return false }
                leftPrevious = leftSelected; rightPrevious = rightSelected
            }
            true
    }
}
