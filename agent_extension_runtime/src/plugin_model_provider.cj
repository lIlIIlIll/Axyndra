package agent_extension_runtime

import std.collection.*
import yjson.*
import yjson_support.*

// Powerless immutable discovery. Invocation requires a real Model Attempt owner,
// never a Tool/Service identity and never authority from this descriptor.
public class PluginModelProviderDescriptor {
    public let name: String
    public let description: String
    public let protocol: String
    public init(name: String, description: String, protocol: String) {
        if (!validCommandName(name) || description.size > 8192 || description.contains("\u{0000}") ||
            protocol != "axyndra.model-provider/v1") {
            throw IllegalArgumentException("invalid ModelProvider declaration")
        }
        this.name = name; this.description = description; this.protocol = protocol
    }
}

func parsePluginModelProviders(ready: JsonNode): JavaScriptHostResult<Array<PluginModelProviderDescriptor>> {
    let raw = match (ready.field("model_providers")) {
        case Some(value) => value; case None => return JavaScriptHostResult.Ok([]) }
    if (raw.unifiedKind != UnifiedJsonKind.List || raw.items.size > 16) {
        return hostError("extension.model_providers_invalid", "ModelProvider discovery is bounded to 16 entries")
    }
    let values = ArrayList<PluginModelProviderDescriptor>()
    for (item in raw.items) {
        if (item.unifiedKind != UnifiedJsonKind.Object || item.fields.size != 3) {
            return hostError("extension.model_provider_invalid", "ModelProvider requires name, description and protocol")
        }
        for (name in ["name", "description", "protocol"]) {
            if (item.field(name).isNone() || item.field(name).getOrThrow().unifiedKind != UnifiedJsonKind.Text) {
                return hostError("extension.model_provider_invalid", "ModelProvider descriptor fields must be strings")
            }
        }
        for (existing in values where existing.name == textField(item, "name")) {
            return hostError("extension.model_provider_duplicate", "duplicate ModelProvider name")
        }
        try { values.add(PluginModelProviderDescriptor(textField(item, "name"), textField(item, "description"),
            textField(item, "protocol"))) }
        catch (_: Exception) { return hostError("extension.model_provider_invalid", "invalid ModelProvider declaration") }
    }
    JavaScriptHostResult.Ok(values.toArray())
}
