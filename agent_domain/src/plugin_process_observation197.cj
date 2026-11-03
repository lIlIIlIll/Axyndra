package agent_domain

import yjson.*
import yjson_support.*

// Trusted normalized DATA boundary. Native supplies neither the effect nor a
// capability. The old exact request/facts/target grammar stays authoritative.
public func pluginHubProcessObservationInputValid197(input: AgentValue): Bool {
    try {
        let op = httpIntentText(input.field("request").getOrThrow(), "op")
        if (op != "ps" && op != "logs" && op != "describe" && op != "wait") { return false }
        pluginHubProcessInputValid180(input)
    } catch (_: Exception) { false }
}

// This predicate does not construct or grant an executing Source. Store and
// Root still verify their actual derived child, same transaction and receipt.
public func isPluginHubProcessObservationPlan197(plan: NormalizedOperationPlan): Bool {
    try {
        pluginPrimitivePlanService111(plan) == "process.observe" &&
            isPluginChildStartPlan111(plan) &&
            pluginHubProcessObservationInputValid197(plan.canonicalArguments.field("intent").getOrThrow().field("input").getOrThrow())
    } catch (_: Exception) { false }
}

// An exact proposal is required before Host performs target preparation.
// Unknown effect/capability fields and another service never become authority.
public func pluginHubProcessObservationIntentValid197(intent: AgentValue): Bool {
    try {
        httpIntentExactFields(intent, ["id", "service", "input"]) &&
            documentContractIdentifier(httpIntentText(intent, "id")) &&
            httpIntentText(intent, "service") == "process.observe" &&
            pluginHubProcessObservationInputValid197(intent.field("input").getOrThrow())
    } catch (_: Exception) { false }
}
