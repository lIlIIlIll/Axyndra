package agent_extension_runtime

import std.collection.*
import yjson.*
import yjson_support.*

// Immutable discovery only. Content results are data: descriptors contain no
// trust, permissions, resource locator grants, context revision or Tool identity.
public class PluginContentProviderDescriptor {
    public let name: String
    public let description: String
    public let protocol: String
    public init(name: String, description: String, protocol: String) {
        if (!validCommandName(name) || description.size > 8192 || description.contains("\u{0000}") ||
            (protocol != "axyndra.context-provider/v1" && protocol != "axyndra.resource-provider/v1" && protocol != "axyndra.policy-provider/v1")) {
            throw IllegalArgumentException("invalid content provider declaration")
        }
        this.name = name; this.description = description; this.protocol = protocol
    }
}

func parsePluginContentProviders(ready: JsonNode, resource: Bool): JavaScriptHostResult<Array<PluginContentProviderDescriptor>> {
    let fieldName = if (resource) { "resource_providers" } else { "context_providers" }
    let protocol = if (resource) { "axyndra.resource-provider/v1" } else { "axyndra.context-provider/v1" }
    parsePluginDataProviders(ready, fieldName, protocol)
}

func parsePluginPolicyProviders(ready: JsonNode): JavaScriptHostResult<Array<PluginContentProviderDescriptor>> {
    parsePluginDataProviders(ready, "providers", "axyndra.policy-provider/v1")
}

func parsePluginDataProviders(ready: JsonNode, fieldName: String, protocol: String): JavaScriptHostResult<Array<PluginContentProviderDescriptor>> {
    let raw = match (ready.field(fieldName)) { case Some(value) => value; case None => return JavaScriptHostResult.Ok([]) }
    if (raw.unifiedKind != UnifiedJsonKind.List || raw.items.size > 32) {
        return hostError("extension.content_providers_invalid", "content provider discovery is bounded to 32 entries per kind")
    }
    let values = ArrayList<PluginContentProviderDescriptor>()
    for (item in raw.items) {
        if (item.unifiedKind != UnifiedJsonKind.Object || item.fields.size != 3) {
            return hostError("extension.content_provider_invalid", "content provider requires exactly name, description and protocol")
        }
        for (name in ["name", "description", "protocol"]) {
            if (item.field(name).isNone() || item.field(name).getOrThrow().unifiedKind != UnifiedJsonKind.Text) {
                return hostError("extension.content_provider_invalid", "content provider fields must be strings")
            }
        }
        if (textField(item, "protocol") != protocol) {
            return hostError("extension.content_provider_protocol", "content provider protocol differs from its declared kind")
        }
        for (existing in values where existing.name == textField(item, "name")) {
            return hostError("extension.content_provider_duplicate", "duplicate content provider name")
        }
        try { values.add(PluginContentProviderDescriptor(textField(item, "name"), textField(item, "description"), protocol)) }
        catch (_: Exception) { return hostError("extension.content_provider_invalid", "invalid content provider declaration") }
    }
    JavaScriptHostResult.Ok(values.toArray())
}

public func samePluginContentProviders(left: Array<PluginContentProviderDescriptor>, right: Array<PluginContentProviderDescriptor>): Bool {
    if (left.size != right.size) { return false }
    for (index in 0..left.size) {
        if (left[index].name != right[index].name || left[index].description != right[index].description ||
            left[index].protocol != right[index].protocol) { return false }
    }
    true
}
