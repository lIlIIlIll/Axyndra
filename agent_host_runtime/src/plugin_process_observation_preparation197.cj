package agent_host_runtime

import agent_domain.*
import tool_runtime.*
import yjson.*
import yjson_support.*

func hostFreezeProcessObservation197(host: HostJavaScriptPluginHost, configuration: HostPrimitiveConfiguration111,
    context: ToolInvocationContext, intents: AgentValue, meter: ?HostPaidValueProjection151): Result<AgentValue> {
    // Refuse malformed or mutating proposals before even target preparation
    // can reach a resource owner. The operator selected this exclusive service.
    if (meter.isNone() || intents.unifiedKind != ValueKind.List || intents.items.size != 1 ||
        !pluginHubProcessObservationIntentValid197(intents.items[0])) {
        return hostPluginResourceError("hub.process_observation_invalid", "expected one exact read-only normalized process observation")
    }
    let copied = configuration.copyPreparedPlan(intents)
    let request = copied.items[0].field("input").getOrThrow().field("request").getOrThrow()
    let target = match (host.observeProcessPreparation180(context, request, meter.getOrThrow())) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    request.put("actual_target", target)
    if (!pluginHubProcessObservationInputValid197(copied.items[0].field("input").getOrThrow())) {
        return hostPluginResourceError("hub.process_observation_invalid", "actual observation target changed the normalized request")
    }
    Result.Ok(copied)
}
