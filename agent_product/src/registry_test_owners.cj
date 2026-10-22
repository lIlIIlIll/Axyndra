package agent_product

import agent_domain.*
import agent_plugin_registry.*
import std.collection.*

// Test cleanup only. Every constructor, parser and allocation is production;
// no mock budget, source or metadata result is injected here.
class ProductRegistryTestOwners {
    private let values = ArrayList<PluginRegistry>()
    private let executionPins = ArrayList<PluginRegistryExecutionPin>()
    func openRegistry(settings: String, workspace: String): PluginRegistry {
        let result = PluginRegistry(settings,workspace); values.add(result); result
    }
    func openProduct(settings: String, workspace: String): ProductPluginRuntime {
        let result = ProductPluginRuntime(settings,workspace); values.add(result); result
    }
    func admission(registry: PluginRegistry, record: ProductPluginRecord): () -> Result<PluginRegistryExecutionFence> {
        let pin = match (registry.captureExecutionPin(record)) {
            case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
            case PluginRegistryResult.Ok(value) => value
        }
        executionPins.add(pin)
        { => match (pin.enter()) {
            case PluginImportResult.Err(error) => Result<PluginRegistryExecutionFence>.Err(
                AgentError(AgentErrorKind.PermissionDenied, error.code, error.message))
            case PluginImportResult.Ok(value) => Result<PluginRegistryExecutionFence>.Ok(value)
        } }
    }
    func close(): Unit {
        for (pin in executionPins) { pin.close() }; executionPins.clear()
        var index = values.size - 1
        while (index >= 0) { values[index].close(); index-- }
        values.clear()
    }
}
