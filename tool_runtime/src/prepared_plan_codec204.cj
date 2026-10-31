package tool_runtime

import agent_domain.*
import std.collection.*
import yjson.*
import yjson_support.*

// Complete original Store DATA field/order/default/framed codec. Only local
// names are suffixed; this producer must be prepaid before its first DOM/UTF8
// allocation. The original Store remains the actual SQL/source validator.
func storedOperationPlanValue204(plan: NormalizedOperationPlan): AgentValue {
    let value = objectValue([
        ValueField("tool", textValue(plan.toolName)),
        ValueField("arguments", plan.canonicalArguments),
        ValueField("capabilities", capabilityValues204(plan.requiredCapabilities)),
        ValueField("paths", stringValues204(plan.resolvedPaths)),
        ValueField("hosts", stringValues204(plan.resolvedHosts)),
        ValueField("network", networkPolicyCanonicalValue(plan.networkPolicy)),
        ValueField("cwd", textValue(plan.cwd)),
        ValueField("environment", objectValue(plan.relevantEnvironment)),
        ValueField("approval", storedApprovalMetadata204(plan.approvalMetadata)),
        ValueField("effect", textValue(storeEffectName204(plan.effectClass))),
        ValueField("retry", textValue(storeRetryName204(plan.retryDisposition))),
        ValueField("replay", replayDispositionValue204(plan.replayDisposition)),
        ValueField("idempotency_key", textValue(plan.idempotencyKey)),
        ValueField("digest", textValue(plan.bindingDigest)),
        ValueField("tool_version", textValue(plan.implementation.toolVersion)),
        ValueField("implementation_fingerprint", textValue(
            plan.implementation.implementationFingerprint
        )),
        ValueField("schema_digest", textValue(plan.implementation.schemaDigest)),
        ValueField("effective_arguments_digest", textValue(
            plan.implementation.effectiveArgumentsDigest
        )),
        ValueField("replay_contract_version", integerValue(
            Int64(plan.implementation.replayContractVersion)
        ))
    ])
    if (!plan.contextReadFacts.isEmpty()) { value.put("context_reads", contextReadFactLinksValue(plan.contextReadFacts)) }
    value
}

func storedApprovalMetadata204(value: ToolApprovalMetadata): AgentValue {
    objectValue([
        ValueField("capability_label", textValue(value.capabilityLabel)),
        ValueField("session_approval_allowed", boolValue(value.sessionApprovalAllowed)),
        ValueField("risk", textValue(approvalRiskLevelName(value.assessment.level))),
        ValueField("flags", stringValues204(value.assessment.flags)),
        ValueField("reasons", stringValues204(value.assessment.reasons)),
        ValueField("grant", objectValue([
            ValueField("capability", textValue(value.grantScope.capability)),
            ValueField("path_prefix", textValue(value.grantScope.pathPrefix)),
            ValueField("tool_name", textValue(value.grantScope.toolName)),
            ValueField("host", textValue(value.grantScope.host)),
            ValueField("session_only", boolValue(value.grantScope.sessionOnly))
        ]))
    ])
}

func replayDispositionValue204(value: ReplayDisposition): AgentValue {
    match (value) {
        case ReplayDisposition.Pure => objectValue([ValueField("kind", textValue("pure"))])
        case ReplayDisposition.SafeReplay => objectValue([
            ValueField("kind", textValue("safe_replay"))
        ])
        case ReplayDisposition.Idempotent(key) => objectValue([
            ValueField("kind", textValue("idempotent")),
            ValueField("key", textValue(key))
        ])
        case ReplayDisposition.RecoverByProbe(probe) => objectValue([
            ValueField("kind", textValue("recover_by_probe")),
            ValueField("probe_id", textValue(probe.value))
        ])
        case ReplayDisposition.Compensatable(plan) => objectValue([
            ValueField("kind", textValue("compensatable")),
            ValueField("compensation_plan_id", textValue(plan.value))
        ])
        case ReplayDisposition.AtMostOnce => objectValue([
            ValueField("kind", textValue("at_most_once"))
        ])
        case ReplayDisposition.NeverReplay => objectValue([
            ValueField("kind", textValue("never_replay"))
        ])
    }
}

func capabilityValues204(capabilities: Array<Capability>): AgentValue {
    let values = ArrayList<AgentValue>()
    for (capability in capabilities) {
        values.add(objectValue([
            ValueField("kind", textValue(storeCapabilityName204(capability.kind))),
            ValueField("resource", textValue(capability.resource))
        ]))
    }
    listValue(values.toArray())
}

func stringValues204(values: Array<String>): AgentValue {
    let result = ArrayList<AgentValue>()
    for (value in values) { result.add(textValue(value)) }
    listValue(result.toArray())
}

func storeCapabilityName204(kind: CapabilityKind): String {
    match (kind) {
        case CapabilityKind.WorkspaceRead => "workspace_read"
        case CapabilityKind.WorkspaceWrite => "workspace_write"
        case CapabilityKind.ProcessSpawn => "process_spawn"
        case CapabilityKind.PeerMessage => "peer_message"
        case CapabilityKind.NetworkAccess => "network_access"
        case CapabilityKind.Delegate => "delegate"
        case CapabilityKind.ExtensionInvoke => "extension_invoke"
    }
}

func storeEffectName204(effect: OperationEffectClass): String {
    match (effect) {
        case OperationEffectClass.ReadOnly => "read_only"
        case OperationEffectClass.WorkspaceMutation => "workspace_mutation"
        case OperationEffectClass.ExternalMutation => "external_mutation"
    }
}

func storeRetryName204(retry: OperationRetryDisposition): String {
    match (retry) {
        case OperationRetryDisposition.Safe => "safe"
        case OperationRetryDisposition.ByIdempotencyKey => "by_idempotency_key"
        case OperationRetryDisposition.VerifyThenRetry => "verify_then_retry"
        case OperationRetryDisposition.Never => "never"
    }
}

func encodeStoredValue204(value: AgentValue): String {
    let output = ArrayList<Byte>()
    appendStoredValue204(output, value)
    String.fromUtf8(output.toArray())
}

func appendStoredValue204(output: ArrayList<Byte>, value: AgentValue): Unit {
    match (value.unifiedKind) {
        case ValueKind.Null => output.add(b'n')
        case ValueKind.Boolean => output.add(if (value.asBool()) { b't' } else { b'f' })
        case ValueKind.Number =>
            output.add(b'd')
            appendStoredFrame204(output, value.asNumberText())
        case ValueKind.Text =>
            output.add(b's')
            appendStoredFrame204(output, value.text)
        case ValueKind.List =>
            output.add(b'l')
            appendStoredFrame204(output, value.items.size.toString())
            for (item in value.items) { appendStoredValue204(output, item) }
        case ValueKind.Object =>
            output.add(b'o')
            appendStoredFrame204(output, value.fields.size.toString())
            for (field in value.fields) {
                appendStoredFrame204(output, field.name)
                appendStoredValue204(output, field.value)
            }
    }
}

func appendStoredFrame204(output: ArrayList<Byte>, value: String): Unit {
    let bytes = unsafe { value.rawData() }
    output.add(all: bytes.size.toString().toArray())
    output.add(b':')
    output.add(all: bytes)
}

func preparedPlanWireValue204(plan: NormalizedOperationPlan): AgentValue {
    let value = storedOperationPlanValue204(plan)
    // Preserve the original in-memory approval summary as well as every
    // original durable field. This extra DATA field confers no authority.
    match (plan.approvalMetadata.writeSummary) {
        case Some(summary) => value.put("write_summary204", objectValue([
            ValueField("path", textValue(summary.path)), ValueField("action", textValue(summary.action)),
            ValueField("exists", boolValue(summary.exists)), ValueField("bytes", integerValue(summary.bytes)),
            ValueField("lines", integerValue(summary.lines)), ValueField("language", textValue(summary.language)),
            ValueField("preview", stringValues204(summary.preview)), ValueField("truncated", boolValue(summary.truncated)),
            ValueField("content_hash", textValue(summary.contentHash)), ValueField("before_bytes", integerValue(summary.beforeBytes)),
            ValueField("added_lines", integerValue(summary.addedLines)), ValueField("removed_lines", integerValue(summary.removedLines))]))
        case None => ()
    }
    value
}
