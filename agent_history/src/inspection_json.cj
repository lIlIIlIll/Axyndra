package agent_history

import agent_app_protocol.*
import agent_domain.*
import yjson.*
import yjson_support.*

// Only the existing redacted inspection DTO is rendered. Raw prompts, arguments,
// Receipt details and artifact content are never added by this serializer.
func inspectionToolEvidenceValue(value: AppRunToolEvidence): AgentValue {
    objectValue([
        ValueField("name", textValue(value.name)),
        ValueField("version", textValue(value.version)),
        ValueField("implementation_fingerprint", textValue(value.implementationFingerprint)),
        ValueField("schema_digest", textValue(value.schemaDigest)),
        ValueField("available", boolValue(value.available))
    ])
}

func inspectionPromptEvidenceValue(value: AppRunPromptEvidence): AgentValue {
    objectValue([
        ValueField("owner", textValue(value.owner)),
        ValueField("scope", textValue(value.scope)),
        ValueField("order", textValue(value.order)),
        ValueField("artifact_hash", textValue(value.artifactHash)),
        ValueField("visibility", textValue(value.visibility))
    ])
}

func inspectionContextEvidenceValue(value: AppRunContextEvidence): AgentValue {
    objectValue([
        ValueField("manifest_id", textValue(value.manifestId)),
        ValueField("manifest_digest", textValue(value.manifestDigest)),
        ValueField("compiler_version", textValue(value.compilerVersion)),
        ValueField("compiler_digest", textValue(value.compilerDigest)),
        ValueField("estimated_tokens", integerValue(value.estimatedTokens)),
        ValueField("token_budget", integerValue(value.tokenBudget)),
        ValueField("active_skill_ids", listValue(value.activeSkillIds.map { item => textValue(item) })),
        ValueField("prompt_contributions", listValue(value.promptContributions.map { item => inspectionPromptEvidenceValue(item) })),
        ValueField("tools", listValue(value.tools.map { item => inspectionToolEvidenceValue(item) }))
    ])
}

func inspectionHistoryEvidenceValue(value: AppRunHistoryEvidence): AgentValue {
    objectValue([
        ValueField("reread_strategy", textValue(value.rereadStrategy)),
        ValueField("checkpoint_id", textValue(value.checkpointId)),
        ValueField("source_digest", textValue(value.sourceDigest)),
        ValueField("projector_version", textValue(value.projectorVersion)),
        ValueField("lane_compatibility", textValue(value.laneCompatibility)),
        ValueField("covers_through_item_ordinal", integerValue(value.coversThroughItemOrdinal)),
        ValueField("structured_summary_available", boolValue(value.structuredSummaryAvailable))
    ])
}

func inspectionModelRequestEvidenceValue(value: AppRunModelRequestEvidence): AgentValue {
    objectValue([
        ValueField("attempt_id", textValue(value.attemptId)),
        ValueField("request_id", textValue(value.requestId)),
        ValueField("semantic_request_id", textValue(value.semanticRequestId)),
        ValueField("parent_attempt_id", textValue(value.parentAttemptId)),
        ValueField("sequence", integerValue(value.sequence)),
        ValueField("attempt_number", integerValue(value.attemptNumber)),
        ValueField("role", textValue(value.role)),
        ValueField("provider_id", textValue(value.providerId)),
        ValueField("model_id", textValue(value.modelId)),
        ValueField("lifecycle", textValue(value.lifecycle)),
        ValueField("dispatch_state", textValue(value.dispatchState)),
        ValueField("replay_barrier", textValue(value.replayBarrier)),
        ValueField("semantic_request_digest", textValue(value.semanticRequestDigest)),
        ValueField("wire_policy_digest", textValue(value.wirePolicyDigest)),
        ValueField("decision_id", textValue(value.decisionId)),
        ValueField("decision", textValue(value.decision)),
        ValueField("decision_content_hash", textValue(value.decisionContentHash)),
        ValueField("usage_source", textValue(value.usageSource)),
        ValueField("input_tokens", (match (value.inputTokens) { case Some(item) => integerValue(item); case None => nullValue() })),
        ValueField("output_tokens", (match (value.outputTokens) { case Some(item) => integerValue(item); case None => nullValue() })),
        ValueField("reasoning_tokens", (match (value.reasoningTokens) { case Some(item) => integerValue(item); case None => nullValue() })),
        ValueField("cache_read_tokens", (match (value.cacheReadTokens) { case Some(item) => integerValue(item); case None => nullValue() })),
        ValueField("cache_write_tokens", (match (value.cacheWriteTokens) { case Some(item) => integerValue(item); case None => nullValue() })),
        ValueField("cost_micros", (match (value.costMicros) { case Some(item) => integerValue(item); case None => nullValue() }))
    ])
}

func inspectionOperationEvidenceValue(value: AppRunOperationEvidence): AgentValue {
    objectValue([
        ValueField("cursor", integerValue(value.cursor)),
        ValueField("operation_id", textValue(value.operationId.value)),
        ValueField("parent_operation_id", (match (value.parentOperationId) { case Some(item) => textValue(item.value); case None => nullValue() })),
        ValueField("tool_name", textValue(value.toolName)),
        ValueField("tool_version", textValue(value.toolVersion)),
        ValueField("implementation_fingerprint", textValue(value.implementationFingerprint)),
        ValueField("schema_digest", textValue(value.schemaDigest)),
        ValueField("effective_arguments_digest", textValue(value.effectiveArgumentsDigest)),
        ValueField("replay_disposition", textValue(value.replayDisposition)),
        ValueField("program_sdk", textValue(value.programSdk)),
        ValueField("program_artifact_hash", textValue(value.programArtifactHash)),
        ValueField("state", textValue(value.state)),
        ValueField("effect_class", textValue(value.effectClass)),
        ValueField("approval_decision", textValue(value.approvalDecision)),
        ValueField("approval_source", textValue(value.approvalSource)),
        ValueField("approval_reasons", listValue(value.approvalReasons.map { item => textValue(item) })),
        ValueField("receipt_outcome", textValue(value.receiptOutcome)),
        ValueField("recovery_guidance", textValue(value.recoveryGuidance))
    ])
}

public func runInspectionValue(value: AppRunInspectionPage): AgentValue {
    objectValue([
        ValueField("thread_id", textValue(value.threadId.value)),
        ValueField("run_id", textValue(value.runId.value)),
        ValueField("thread_revision", integerValue(value.threadRevision)),
        ValueField("run_state", textValue(value.runState)),
        ValueField("provider_id", textValue(value.providerId)),
        ValueField("model_id", textValue(value.modelId)),
        ValueField("composition_profile", textValue(value.compositionProfile)),
        ValueField("composition_version", textValue(value.compositionVersion)),
        ValueField("composition_digest", textValue(value.compositionDigest)),
        ValueField("tool_visibility_digest", textValue(value.toolVisibilityDigest)),
        ValueField("prompt_graph_digest", textValue(value.promptGraphDigest)),
        ValueField("component_instances", listValue(value.componentInstances.map { item => textValue(item) })),
        ValueField("active_skill_ids", listValue(value.activeSkillIds.map { item => textValue(item) })),
        ValueField("contexts", listValue(value.contexts.map { item => inspectionContextEvidenceValue(item) })),
        ValueField("history", inspectionHistoryEvidenceValue(value.history)),
        ValueField("model_requests", listValue(value.modelRequests.map { item => inspectionModelRequestEvidenceValue(item) })),
        ValueField("operations", listValue(value.operations.map { item => inspectionOperationEvidenceValue(item) })),
        ValueField("warnings", listValue(value.warnings.map { item => textValue(item) })),
        ValueField("next_before_cursor", integerValue(value.nextBeforeCursor))
    ])
}

