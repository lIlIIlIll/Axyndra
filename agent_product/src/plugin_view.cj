package agent_product

import agent_domain.*
import agent_host_runtime.*
import yjson.*
import yjson_support.*

func queryProductPluginView(runtime: ProductRuntime, route: String, context: AgentValue,
    input: AgentValue, thread: ThreadId, cancellation: CancellationToken, requestId: String): Result<HostPluginViewResult> {
    for (selected in runtime.javascriptPluginViews() where selected.routeName == route) {
        let host = runtime.vnext.javascriptPlugins
        let binding = match (host.viewBinding(selected.extensionId, selected.name)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (binding.generation != selected.instanceGeneration) {
            return pluginViewObservationError("view.changed", "View generation changed during selection") }
        return hostQueryPluginView(host, binding.namespace, binding.contribution, binding.digest,
            context, input, thread, cancellation, requestId)
    }
    pluginViewObservationError("view.missing", "no active View has the requested route")
}

// Keep the complete synchronous consumer helper separate from retirement.
// The callback may serialize/copy DATA but must not retain borrowed DOM nodes.
func consumeProductPluginView<T>(view: HostPluginViewResult, metadata: AgentValue, primary: String,
    consume: (AgentValue, AgentValue, String) -> Result<T>): Result<T> {
    consume(metadata, view.value, primary)
}

func pluginViewObservationError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.InvalidInput, code, message))
}
