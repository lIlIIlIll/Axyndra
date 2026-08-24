package agent_domain

import json4cj.*
import json4cj as generic_json

// Product compatibility names over the canonical generic validator.
public type JsonSchemaViolation = generic_json.JsonSchemaViolation

public func validateAgentValueSchema(
    schema: AgentValue,
    value: AgentValue
): ?JsonSchemaViolation {
    validateJsonSchema(schema, value)
}
