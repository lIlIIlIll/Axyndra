package agent_domain

import yjson.*
import yjson_support.*

public func validateAgentValueSchema(
    schema: AgentValue,
    value: AgentValue
): ?UnifiedJsonSchemaViolation {
    validateUnifiedJsonSchema(schema, value)
}
