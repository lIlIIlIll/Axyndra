package agent_product

import agent_app_protocol.*

public func renderRunInspection(page: AppRunInspectionPage): String {
    var output = "Run " + page.runId.value + "\n"
    output += "  thread: " + page.threadId.value + "\n"
    output += "  state: " + page.runState + "\n"
    output += "  model: " + inspectionDisplay(page.providerId) + "/" +
        inspectionDisplay(page.modelId) + "\n"
    output += "  composition: " + inspectionDisplay(page.compositionProfile) + "@" +
        inspectionDisplay(page.compositionVersion) + " digest=" +
        inspectionDisplay(page.compositionDigest) + "\n"
    output += "  tool_visibility_digest: " + inspectionDisplay(page.toolVisibilityDigest) + "\n"
    output += "  prompt_graph_digest: " + inspectionDisplay(page.promptGraphDigest) + "\n"
    output += "  components: " + inspectionJoin(page.componentInstances) + "\n"
    output += "  active_skills: " + inspectionJoin(page.activeSkillIds) + "\n"

    output += "\nContexts\n"
    if (page.contexts.isEmpty()) {
        output += "  (none recorded)\n"
    }
    for (context in page.contexts) {
        output += "  " + context.manifestId + " digest=" + context.manifestDigest +
            " compiler=" + inspectionDisplay(context.compilerVersion) +
            " estimated_tokens=" + context.estimatedTokens.toString() +
            " budget=" + context.tokenBudget.toString() + "\n"
        output += "    skills: " + inspectionJoin(context.activeSkillIds) + "\n"
        for (prompt in context.promptContributions) {
            output += "    prompt owner=" + prompt.owner + " scope=" + prompt.scope +
                " order=" + prompt.order + " visibility=" + prompt.visibility +
                " artifact=" + prompt.artifactHash + "\n"
        }
        for (tool in context.tools) {
            output += "    tool " + tool.name + " version=" + inspectionDisplay(tool.version) +
                " available=" + tool.available.toString() +
                " implementation=" + inspectionDisplay(tool.implementationFingerprint) +
                " schema=" + inspectionDisplay(tool.schemaDigest) + "\n"
        }
    }

    output += "\nHistory reread\n"
    output += "  strategy: " + page.history.rereadStrategy + "\n"
    if (page.history.checkpointId == "") {
        output += "  checkpoint: unavailable\n"
    } else {
        output += "  checkpoint: " + page.history.checkpointId +
            " covers_item=" + page.history.coversThroughItemOrdinal.toString() +
            " source_digest=" + inspectionDisplay(page.history.sourceDigest) +
            " projector=" + inspectionDisplay(page.history.projectorVersion) +
            " lane=" + inspectionDisplay(page.history.laneCompatibility) +
            " structured_summary=" + page.history.structuredSummaryAvailable.toString() + "\n"
    }

    output += "\nModel requests\n"
    if (page.modelRequests.isEmpty()) {
        output += "  (none recorded)\n"
    }
    for (request in page.modelRequests) {
        output += "  " + request.sequence.toString() + ". " + request.requestId +
            " role=" + request.role + " provider=" + inspectionDisplay(request.providerId) +
            " model=" + inspectionDisplay(request.modelId) +
            " decision=" + request.decision + " usage_source=" + request.usageSource
        output += "\n    attempt_id=" + request.attemptId +
            " semantic_request=" + request.semanticRequestId +
            " attempt_number=" + request.attemptNumber.toString() +
            " parent_attempt=" + inspectionDisplay(request.parentAttemptId) +
            " lifecycle=" + request.lifecycle + " dispatch=" + request.dispatchState +
            " replay_barrier=" + request.replayBarrier
        output += "\n    semantic_digest=" + inspectionDisplay(request.semanticRequestDigest) +
            " wire_policy_digest=" + inspectionDisplay(request.wirePolicyDigest) +
            " decision_id=" + inspectionDisplay(request.decisionId) +
            " content_hash=" + inspectionDisplay(request.decisionContentHash) +
            " (identity only; not cache-hit evidence)"
        if (request.usageSource == "unknown") {
            output += " usage=unknown cost=unknown"
        } else {
            output += " input=" + inspectionOptionalInt(request.inputTokens) +
                " output=" + inspectionOptionalInt(request.outputTokens) +
                " reasoning=" + inspectionOptionalInt(request.reasoningTokens) +
                " cache_read=" + inspectionOptionalInt(request.cacheReadTokens) +
                " cache_write=" + inspectionOptionalInt(request.cacheWriteTokens) +
                " cost_micros=" + inspectionOptionalInt(request.costMicros)
        }
        output += "\n"
    }

    output += "\nOperations (newest first)\n"
    if (page.operations.isEmpty()) {
        output += "  (none recorded)\n"
    }
    for (operation in page.operations) {
        output += "  cursor=" + operation.cursor.toString() + " id=" + operation.operationId.value +
            " tool=" + operation.toolName + "@" + inspectionDisplay(operation.toolVersion) +
            " state=" + operation.state + " effect=" + operation.effectClass +
            " approval=" + operation.approvalDecision + "/" + operation.approvalSource +
            " receipt=" + operation.receiptOutcome + "\n"
        output += "    identity implementation=" +
            inspectionDisplay(operation.implementationFingerprint) + " schema=" +
            inspectionDisplay(operation.schemaDigest) +
            " arguments_digest=" + inspectionDisplay(operation.effectiveArgumentsDigest) +
            " replay=" + inspectionDisplay(operation.replayDisposition) + "\n"
        if (!operation.approvalReasons.isEmpty()) {
            output += "    approval_reasons: " + inspectionJoin(operation.approvalReasons) + "\n"
        }
        if (operation.recoveryGuidance != "") {
            output += "    recovery: " + operation.recoveryGuidance + "\n"
        }
        if (operation.programSdk != "") {
            output += "    program sdk=" + operation.programSdk + " artifact_hash=" +
                inspectionDisplay(operation.programArtifactHash) + "\n"
        }
    }
    if (page.nextBeforeCursor > 0) {
        output += "  more: /inspect " + page.runId.value + " " +
            page.nextBeforeCursor.toString() + "\n"
    }

    if (!page.warnings.isEmpty()) {
        output += "\nWarnings\n"
        for (warning in page.warnings) { output += "  - " + warning + "\n" }
    }
    output
}

func inspectionDisplay(value: String): String {
    if (value.trimAscii() == "") { "unavailable" } else { value }
}

func inspectionOptionalInt(value: ?Int64): String {
    match (value) {
        case Some(actual) => actual.toString()
        case None => "unknown"
    }
}

func inspectionJoin(values: Array<String>): String {
    if (values.isEmpty()) { return "(none)" }
    var result = ""
    for (value in values) {
        if (result != "") { result += ", " }
        result += value
    }
    result
}
