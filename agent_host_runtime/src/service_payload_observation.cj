package agent_host_runtime


import agent_domain.*
import tool_runtime.*
import yjson_support.*

func hostServicePayloadRetainedObservation(context: ToolInvocationContext, prepared: PreparedToolInvocation,
    value: AgentValue, owner: ?HostPluginLifecycleOwner): ?OperationObservation {
    let encoded = stringifyUnifiedJson(value)
    if (encoded.size <= 65536) {
        try { return Some(OperationObservation(encoded)) } catch (_: Exception) {}
    } else {
        match (owner) {
            case Some(store) => match (store.retainObservation(context, prepared, value)) {
                case Result.Ok(observation) => return Some(observation)
                case Result.Err(_) => ()
            }
            case None => ()
        }
    }
    // Failed retention is explicit. This digest is diagnostic, not a claim
    // that an artifact exists or is retained by a canonical history reference.
    Some(OperationObservation(stringifyUnifiedJson(objectValue([
        ValueField("omitted", boolValue(true)), ValueField("bytes", integerValue(encoded.size)),
        ValueField("sha256", textValue(modelPolicySha256Text(encoded))),
        ValueField("reason", textValue("observation_artifact_not_retained"))]))))
}

public func hostServiceObservationHex(bytes: Array<Byte>): String { hostArtifactHex(bytes) }
