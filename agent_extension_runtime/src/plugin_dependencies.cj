package agent_extension_runtime

import agent_sdk.*
import std.collection.*
import yjson.*
import yjson_support.*

// A dependency identifies a declared component, not an execution permission.
// Its version is the containing immutable package version. No code is loaded
// during resolution and no dependency is implicitly installed or enabled.
public class PluginContributionDependency {
    public let namespace: String
    public let versionRange: String
    public let kind: PluginContributionKind
    public let name: String
    private let versions: SdkCompatibility

    public init(namespace: String, versionRange: String, kind: PluginContributionKind, name: String) {
        if (!namespace.startsWith("axyndra:") || namespace.size > 256 ||
            !validCommandName(namespace[8..]) ||
            !(if (kind == PluginContributionKind.Tool) { validToolName(name) } else { validCommandName(name) })) {
            throw IllegalArgumentException("dependency requires an exact native package and component identity")
        }
        match (kind) {
            case PluginContributionKind.Tool | PluginContributionKind.Command | PluginContributionKind.Service |
                PluginContributionKind.ModelProvider | PluginContributionKind.Provider | PluginContributionKind.ContextProvider | PluginContributionKind.ResourceProvider => ()
            case _ => throw IllegalArgumentException("unsupported dependency contribution kind")
        }
        let bounds = dependencyVersionRange(versionRange)
        this.namespace = namespace; this.versionRange = versionRange
        this.kind = kind; this.name = name; this.versions = bounds
    }

    public func matches(descriptor: PluginPackageDescriptor): Bool {
        if (descriptor.namespace != namespace || descriptor.entryKind != PluginEntryKind.NativeExecutable) { return false }
        let version = match (requiredVersion(jsonObject([JsonObjectEntry("version", jsonString(descriptor.version))]), "version", "", "dependency")) {
            case ExtensionRuntimeResult.Ok(value) => value
            case ExtensionRuntimeResult.Err(_) => return false
        }
        if (!versions.includes(version)) { return false }
        for (contribution in descriptor.contributions where contribution.kind == kind && contribution.name == name) { return true }
        false
    }
    public func identity(): String { namespace + "/" + pluginContributionKindName(kind) + "/" + name }
}

func dependencyVersionRange(source: String): SdkCompatibility {
    if (source.size > 128 || !source.startsWith("[") || !source.endsWith(")")) {
        throw IllegalArgumentException("dependency version_range requires [MAJOR.MINOR.PATCH,MAJOR.MINOR.PATCH)")
    }
    let values = source[1..source.size - 1].split(",")
    if (values.size != 2) { throw IllegalArgumentException("dependency version_range requires two bounds") }
    let lower = match (requiredVersion(jsonObject([JsonObjectEntry("version", jsonString(values[0]))]), "version", "", "dependency")) {
        case ExtensionRuntimeResult.Ok(value) => value
        case ExtensionRuntimeResult.Err(_) => throw IllegalArgumentException("dependency minimum version is not canonical")
    }
    let upper = match (requiredVersion(jsonObject([JsonObjectEntry("version", jsonString(values[1]))]), "version", "", "dependency")) {
        case ExtensionRuntimeResult.Ok(value) => value
        case ExtensionRuntimeResult.Err(_) => throw IllegalArgumentException("dependency maximum version is not canonical")
    }
    SdkCompatibility(lower, upper)
}

func parsePluginContributionDependencies(value: JsonNode, entryKind: PluginEntryKind,
    source: String): PluginPackageResult<Array<PluginContributionDependency>> {
    let declared = match (value.field("component_dependencies")) {
        case None => return PluginPackageResult.Ok(Array<PluginContributionDependency>())
        case Some(items) => items
    }
    if (entryKind != PluginEntryKind.NativeExecutable || declared.unifiedKind != UnifiedJsonKind.List || declared.items.size > 32) {
        return pluginPackageError("plugin.component_dependencies_invalid", "native component_dependencies must be a list of at most 32 exact requirements",
            source: source, field: "component_dependencies")
    }
    // Older hosts know sdk_range but would not understand this new field.
    // Require an author-declared minimum so they reject before execution.
    if (!declared.items.isEmpty()) {
        let minimum = try { dependencyVersionRange(textField(value, "sdk_range")).minimum }
            catch (_: Exception) { return pluginPackageError("plugin.component_dependency_sdk", "component dependencies require SDK minimum 2.1.0", source: source, field: "sdk_range") }
        if (minimum.lessThan(SemanticVersion(2, 1, 0))) {
            return pluginPackageError("plugin.component_dependency_sdk", "component dependencies require SDK minimum 2.1.0", source: source, field: "sdk_range")
        }
    }
    let result = ArrayList<PluginContributionDependency>()
    let seen = HashSet<String>()
    for (row in declared.items) {
        if (row.unifiedKind != UnifiedJsonKind.Object || row.fields.size != 4) {
            return pluginPackageError("plugin.component_dependency_invalid", "component dependency requires namespace, version_range, kind and name only",
                source: source, field: "component_dependencies")
        }
        let fields = HashSet<String>()
        for (field in row.fields) {
            if (!["namespace", "version_range", "kind", "name"].contains(field.name) || fields.contains(field.name) || field.value.unifiedKind != UnifiedJsonKind.Text) {
                return pluginPackageError("plugin.component_dependency_invalid", "dependency fields must be unique, known strings", source: source, field: "component_dependencies")
            }
            fields.add(field.name)
        }
        let declaration = match (parseNativePluginContributions(jsonObject([JsonObjectEntry("contributions", jsonArray([
            jsonObject([JsonObjectEntry("kind", jsonString(textField(row, "kind"))), JsonObjectEntry("name", jsonString(textField(row, "name")))])]))]), source)) {
            case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
            case PluginPackageResult.Ok(values) => values[0]
        }
        let dependency = try { PluginContributionDependency(textField(row, "namespace"), textField(row, "version_range"), declaration.kind, declaration.name) }
            catch (_: Exception) { return pluginPackageError("plugin.component_dependency_invalid", "dependency identity or bounded version interval is invalid", source: source, field: "component_dependencies") }
        if (seen.contains(dependency.identity())) {
            return pluginPackageError("plugin.component_dependency_duplicate", "duplicate dependency: " + dependency.identity(), source: source, field: "component_dependencies")
        }
        seen.add(dependency.identity()); result.add(dependency)
    }
    PluginPackageResult.Ok(result.toArray())
}

// Derived, bounded view over the existing installed records. There is no
// registry, generation counter, mutable plugin state or permission inheritance.
public class PluginDependencyNode {
    public let descriptor: PluginPackageDescriptor
    public let enabled: Bool
    public init(descriptor: PluginPackageDescriptor, enabled: Bool) { this.descriptor = descriptor; this.enabled = enabled }
}

class PluginDependencyTraversal {
    let nodes: Array<PluginDependencyNode>
    let visiting = HashSet<String>()
    let visited = HashSet<String>()
    let order = ArrayList<PluginPackageDescriptor>()
    init(nodes: Array<PluginDependencyNode>) { this.nodes = nodes.clone() }

    func visit(value: PluginPackageDescriptor, depth: Int64): PluginPackageResult<Unit> {
        if (depth > 32) { return pluginPackageError("plugin.component_dependency_depth", "dependency depth exceeds 32", field: value.namespace) }
        if (visiting.contains(value.namespace)) { return pluginPackageError("plugin.component_dependency_cycle", "dependency cycle reaches " + value.namespace, field: value.namespace) }
        if (visited.contains(value.namespace)) { return PluginPackageResult.Ok(()) }
        visiting.add(value.namespace)
        for (dependency in value.componentDependencies) {
            var found: ?PluginDependencyNode = None
            for (node in nodes where node.descriptor.namespace == dependency.namespace) { found = Some(node) }
            let child = match (found) {
                case Some(node) => node
                case None => return pluginPackageError("plugin.component_dependency_missing", value.namespace + " requires " + dependency.identity(), field: value.namespace)
            }
            if (!dependency.matches(child.descriptor)) {
                return pluginPackageError("plugin.component_dependency_incompatible", value.namespace + " requires " + dependency.identity() + " " + dependency.versionRange, field: value.namespace)
            }
            match (visit(child.descriptor, depth + 1)) { case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error); case PluginPackageResult.Ok(_) => () }
        }
        visiting.remove(value.namespace); visited.add(value.namespace); order.add(value)
        PluginPackageResult.Ok(())
    }
}

public func resolvePluginDependencies(root: PluginPackageDescriptor,
    nodes: Array<PluginDependencyNode>): PluginPackageResult<Array<PluginPackageDescriptor>> {
    if (root.componentDependencies.isEmpty()) { return PluginPackageResult.Ok([root]) }
    if (nodes.size > 256) { return pluginPackageError("plugin.component_dependency_capacity", "dependency graph exceeds 256 effective installed packages") }
    let identities = HashSet<String>()
    for (node in nodes) {
        if (identities.contains(node.descriptor.namespace)) { return pluginPackageError("plugin.component_dependency_ambiguous", "duplicate effective namespace " + node.descriptor.namespace) }
        identities.add(node.descriptor.namespace)
    }
    let traversal = PluginDependencyTraversal(nodes)
    match (traversal.visit(root, 0)) { case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error); case PluginPackageResult.Ok(_) => () }
    for (descriptor in traversal.order where descriptor.namespace != root.namespace) {
        for (node in nodes where node.descriptor.namespace == descriptor.namespace && !node.enabled) {
            return pluginPackageError("plugin.component_dependency_disabled", root.namespace + " requires explicitly enabled " + descriptor.namespace, field: root.namespace)
        }
    }
    PluginPackageResult.Ok(traversal.order.toArray())
}
