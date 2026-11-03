package agent_domain

import yjson.*
import yjson_support.*

// Diagnostic data attached to an existing canonical error/Receipt. Its content
// is never authorization, verification or a new source of execution identity.
// Freeze JSON bytes, then parse a new copy for every projection so callers
// cannot mutate a retained observation through JsonNode's mutable fields.
public class OperationObservation {
    private let encoded: String
    public init(encoded: String) {
        if (encoded.size == 0 || encoded.size > 65536) {
            throw IllegalArgumentException("operation observation exceeds its inline byte bound")
        }
        let value = parseUnifiedJson(encoded, maxBytes: 65536, maxDepth: 32)
        let frozen = stringifyUnifiedJson(value)
        if (frozen.size > 65536) {
            throw IllegalArgumentException("operation observation exceeds its encoded byte bound")
        }
        this.encoded = frozen
    }
    // Immutable diagnostic DATA only. The caller must keep its real paid
    // consumer alive throughout this loan, and retain a distinct consumer for
    // any captured alias. Unit return does not acknowledge an external alias.
    // This exposes no Source, verification, execution or retry authority.
    public func withFrozenEncodedData113(consume: (String) -> Unit): Unit {
        consume(encoded)
    }
    public func frozenEncodedByteSize113(): Int64 { encoded.size }
    public func toValue(): AgentValue {
        objectValue([
            ValueField("schema", textValue("axyndra.operation-observation/v1")),
            ValueField("trust", textValue("untrusted_data")),
            ValueField("authorizes_effects", boolValue(false)),
            ValueField("content", parseUnifiedJson(encoded, maxBytes: 65536, maxDepth: 32))
        ])
    }
}
