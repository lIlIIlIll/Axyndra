package agent_product

import agent_domain.*
import agent_runtime.*
import tool_runtime.*

// Actual file-plan construction DATA on the existing Registry bank. Neither
// this outcome nor its copy acknowledgement grants approval or execution.
func ownedProductFilePlanCanonical204(catalog: ToolCatalog, context: ToolInvocationContext,
    call: ToolCall, workspace: LocalWorkspace, artifacts: ProductArtifactStore,
    operations: OperationRuntimePort, recovery: Bool): Result<ToolCanonicalArgumentsOwner204> {
    let paid = match (catalog.reserveRegistryData180(131072)) {
        case Some(value) => value
        case None => return Result.Err(AgentError(AgentErrorKind.Configuration,
            "application_plan.canonical_bank_missing", "file plan requires its actual Registry DATA bank")) }
    let owner = try { ToolCanonicalArgumentsOwner204(paid) }
        catch (error: Exception) { paid.close(); throw error }
    try {
        // Existing durable plans are bounded to 1 MiB. Fund construction and
        // retained output before loading/copying the actual plan graph.
        owner.fundAdditional204(8388608)
        buildProductFilePlanCanonicalFrame204(owner, context, call, workspace, artifacts, operations, recovery)
        owner.producerFrameReturned204()
        Result.Ok(owner)
    } catch (error: Exception) {
        // Only an exact recorded pre-copy refusal is nonacceptance. Every
        // unknown producer/copy error retains its original DATA and payment.
        if (owner.closeUnacceptedProducer204(error)) {
            return Result.Err(AgentError(AgentErrorKind.BudgetExceeded, "tool.canonical_data_refused",
                "file plan DATA cannot fit the original shared payload capacity")) }
        owner.holdUnknownConsumer204(); throw error
    }
}
private func buildProductFilePlanCanonicalFrame204(owner: ToolCanonicalArgumentsOwner204,
    context: ToolInvocationContext, call: ToolCall, workspace: LocalWorkspace,
    artifacts: ProductArtifactStore, operations: OperationRuntimePort, recovery: Bool): Unit {
    let result = if (recovery) { canonicalizeProductFileRecoveryPlan(context, call, workspace, artifacts,
        operationRuntime: Some(operations)) }
        else { canonicalizeProductFileApplicationPlan(context, call, workspace, artifacts,
            operationRuntime: Some(operations)) }
    match (result) { case Result.Err(error) => owner.installProducerError204(error)
        case Result.Ok(value) => owner.installProducerData204(value) }
}
