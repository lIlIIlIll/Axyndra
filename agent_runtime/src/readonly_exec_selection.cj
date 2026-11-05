package agent_runtime

import agent_domain.*
import yjson.*
import yjson_support.*

// Immutable descriptive data, not a Source, approval or executable seal.
// Only the opt-in Store API plus its actual Host guard may admit this family.
public class ReadonlyExecDerivedSelection {
    private let encoded: String
    public init(value: AgentValue) { encoded = stringifyUnifiedJson(value) }
    public prop value: AgentValue { get() { parseUnifiedJson(encoded, maxBytes: 65536) } }
}
