package agent_app

import agent_core.*
import agent_domain.*
import agent_product.*
import agent_runtime.*
import tool_runtime.*
import yjson.*
import yjson_support.*

// This helper is entered only after the existing broker authenticates the
// operator peer. The request contains original operator flag DATA, not Source
// or Prepared authority. One immutable value is installed on its Root-local
// Session before any resolution, normalization, preparation or Model turn.
func ownerOperatorOptions180(product: ProductRuntime, request: AgentValue,
    metadata: LogicalJsonOwnerReservation): ProductOperatorOptions180 {
    // Pay the overlapping original request/argument and frozen settings views
    // from the actual frontend's already-owned bank before either is copied.
    let meter = ToolSnapshotMeasure159(metadata)
    meter.addValue159(request); meter.addValue159(request); meter.addSlots159(64); meter.fund159()
    let arguments = ownerFrontendArguments180(request.field("options").getOrThrow())
    let routing = if (ownerFrontendText180(request, "command") == "reviewer-dry-run") {
        Some(ApprovalRoutingMode.Ai)
    } else { approvalRoutingModeFrom(arguments) }
    let approval = match (routing) {
        case Some(ApprovalRoutingMode.Trusted) => ApprovalMode.Yolo
        case _ => approvalModeFrom(arguments)
    }
    let network = match (shellNetworkModeFrom(arguments)) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw OwnedCanonicalDataFailure113(error)
    }
    let profile = modelStreamFaultProfileFrom(arguments)
    let counters = if (profile.isSome()) { Some(ModelStreamFaultCounters180(metadata)) }
        else { None<ModelStreamFaultCounters180> }
    ProductOperatorOptions180(approvalMode: approval,
        approvalRoutingModeOverride: routing, shellNetworkModeOverride: network,
        wallTimeoutMillis: wallTimeoutFrom(arguments), modelAttemptRecovery: modelAttemptRecoveryFrom(arguments),
        modelStreamFaultProfile: profile, modelFaultCounters180: counters,
        modelOverride: argumentValue(arguments, "--model"))
}

func ownerApplicationSession180(product: ProductRuntime, request: AgentValue,
    metadata: LogicalJsonOwnerReservation,
    sessionId!: ?SessionId = None<SessionId>,
    frontendCancellation180!: ?CancellationToken = None<CancellationToken>,
    frontendOptions180!: ?ProductOperatorOptions180 = None<ProductOperatorOptions180>): ApplicationSession {
    let options = match (frontendOptions180) { case Some(value) => value
        case None => ownerOperatorOptions180(product, request, metadata) }
    ApplicationSession(product, sessionId: sessionId, operatorOptions180: Some(options),
        frontendCancellation180: frontendCancellation180)
}

