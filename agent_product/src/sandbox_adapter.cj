package agent_product

import agent_domain.*
import sandbox4cj.*
import std.collection.*

// sandbox4cj is deliberately independent from the Agent domain.  This is the
// single product boundary that translates its mechanical enforcement errors
// into runtime errors; callers must not reinterpret sandbox failures.
func sandboxAgentError(error: SandboxError): AgentError {
    let kind = match (error.kind) {
        case SandboxErrorKind.Configuration => AgentErrorKind.Configuration
        case SandboxErrorKind.InvalidInput => AgentErrorKind.InvalidInput
        case SandboxErrorKind.PermissionDenied => AgentErrorKind.PermissionDenied
        case SandboxErrorKind.Transport => AgentErrorKind.Transport
        case SandboxErrorKind.Cancelled => AgentErrorKind.Cancelled
        case SandboxErrorKind.Deadline => AgentErrorKind.Timeout
    }
    let fields = ArrayList<ErrorField>()
    for (field in error.fields) { fields.add(ErrorField(field.name, field.value)) }
    AgentError(kind, error.code, error.message, fields: fields.toArray())
}
