package agent_product

import agent_plugin_registry.*
import std.collection.*

// Test cleanup only. Every constructor, parser and allocation is production;
// no mock budget, source or metadata result is injected here.
class ProductRegistryTestOwners {
    private let values = ArrayList<PluginRegistry>()
    func openRegistry(settings: String, workspace: String): PluginRegistry {
        let result = PluginRegistry(settings,workspace); values.add(result); result
    }
    func openProduct(settings: String, workspace: String): ProductPluginRuntime {
        let result = ProductPluginRuntime(settings,workspace); values.add(result); result
    }
    func close(): Unit {
        var index = values.size - 1
        while (index >= 0) { values[index].close(); index-- }
        values.clear()
    }
}
