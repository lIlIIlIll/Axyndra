package agent_extension_runtime

import std.collection.*
import yjson.*
import yjson_support.*

// An immutable route declaration. It is neither a Tool nor a host service grant.
public class PluginServiceDescriptor {
    public let name: String
    public let description: String
    public let supportsPreparationReference: Bool
    public init(name: String, description: String, supportsPreparationReference!: Bool = false) {
        if (!validCommandName(name) || description.size > 8192 || description.contains("\u{0000}")) {
            throw IllegalArgumentException("invalid service declaration")
        }
        this.name = name; this.description = description
        this.supportsPreparationReference = supportsPreparationReference
    }
}

func parsePluginServices(ready: JsonNode): JavaScriptHostResult<Array<PluginServiceDescriptor>> {
    let value = match (ready.field("services")) {
        case Some(item) => item
        case None => return JavaScriptHostResult.Ok([])
    }
    if (value.unifiedKind != UnifiedJsonKind.List || value.items.size > 64) {
        return hostError("extension.services_invalid", "services must contain at most 64 declarations")
    }
    let services = ArrayList<PluginServiceDescriptor>()
    for (item in value.items) {
        if (item.unifiedKind != UnifiedJsonKind.Object || (item.fields.size != 2 && item.fields.size != 3) ||
            item.field("name").isNone() || item.field("description").isNone() ||
            item.field("name").getOrThrow().unifiedKind != UnifiedJsonKind.Text ||
            item.field("description").getOrThrow().unifiedKind != UnifiedJsonKind.Text) {
            return hostError("extension.service_invalid", "service declaration requires name and description only")
        }
        let supportsReference = match (item.field("supports_preparation_reference")) {
            case None =>
                if (item.fields.size != 2) { return hostError("extension.service_invalid", "unknown service declaration field") }
                false
            case Some(flag) =>
                if (flag.unifiedKind != UnifiedJsonKind.Boolean) { return hostError("extension.service_invalid", "preparation reference support must be boolean") }
                flag.boolValue
        }
        let name = textField(item, "name")
        for (existing in services where existing.name == name) {
            return hostError("extension.service_duplicate", "service declaration is duplicated")
        }
        try { services.add(PluginServiceDescriptor(name, textField(item, "description"), supportsPreparationReference: supportsReference)) }
        catch (_: Exception) { return hostError("extension.service_invalid", "service declaration is invalid or oversized") }
    }
    JavaScriptHostResult.Ok(services.toArray())
}
