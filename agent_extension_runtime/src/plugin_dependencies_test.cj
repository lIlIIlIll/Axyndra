package agent_extension_runtime

import agent_sdk.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func dependencyTestManifest(id: String, dependencies: String): String {
    "{\"id\":\"" + id + "\",\"version\":\"1.0.0\",\"entrypoint\":\"worker\",\"entry_kind\":\"native-executable\"," +
        "\"sdk_range\":\"[2.1.0,3.0.0)\",\"protocol_range\":\"axyndra-js-host-v2\"," +
        "\"contributions\":[{\"kind\":\"command\",\"name\":\"hello\"}],\"component_dependencies\":" + dependencies + "}"
}
func dependencyTestRow(namespace: String, range!: String = "[1.0.0,2.0.0)", kind!: String = "command", name!: String = "hello"): String {
    stringifyUnifiedJson(jsonObject([JsonObjectEntry("namespace", jsonString(namespace)), JsonObjectEntry("version_range", jsonString(range)),
        JsonObjectEntry("kind", jsonString(kind)), JsonObjectEntry("name", jsonString(name))]))
}
func dependencyTestDescriptor(id: String, dependencies!: String = "[]"): PluginPackageDescriptor {
    match (parsePluginPackageManifest(PluginManifestFamily.Axyndra, dependencyTestManifest(id, dependencies))) {
        case PluginPackageResult.Ok(value) => value
        case PluginPackageResult.Err(error) => throw IllegalStateException(error.code + ":" + error.message)
    }
}
func dependencyError<T>(value: PluginPackageResult<T>): String {
    match (value) { case PluginPackageResult.Err(error) => error.code; case PluginPackageResult.Ok(_) => "" }
}

@Test
class PluginComponentDependencyTests {
    @TestCase
    func strictMetadataRejectsUnknownDuplicateAndUnboundedRequirements(): Unit {
        let row = dependencyTestRow("axyndra:dependency")
        var tooMany = "["
        for (index in 0..33) { if (index > 0) { tooMany += "," }; tooMany += row }
        tooMany += "]"
        let malformed = ["{}", "[" + row + "," + row + "]", "[" + dependencyTestRow("pi:dependency") + "]",
            "[" + dependencyTestRow("axyndra:dependency", range: "*") + "]",
            "[" + dependencyTestRow("axyndra:dependency", range: "[2.0.0,1.0.0)") + "]",
            "[" + dependencyTestRow("axyndra:dependency", kind: "authority") + "]",
            "[" + row[..row.size - 1] + ",\"grant\":\"workspace.write\"}]",
            "[" + row[..row.size - 1] + ",\"namespace\":\"axyndra:other\"}]",
            tooMany]
        for (dependencies in malformed) {
            @Expect(parsePluginPackageManifest(PluginManifestFamily.Axyndra, dependencyTestManifest("consumer", dependencies)).isOk(), false)
        }
        let descriptor = dependencyTestDescriptor("consumer", dependencies: "[" + row + "]")
        @Expect(dependencyError(parsePluginPackageManifest(PluginManifestFamily.Axyndra,
            dependencyTestManifest("consumer", "[" + row + "]").replace("[2.1.0,3.0.0)", "[2.0.0,3.0.0)"))), "plugin.component_dependency_sdk")
        @Expect(descriptor.componentDependencies.size, 1)
        let values = descriptor.componentDependencies
        values[0] = PluginContributionDependency("axyndra:other", "[1.0.0,2.0.0)", PluginContributionKind.Command, "hello")
        @Expect(descriptor.componentDependencies[0].namespace, "axyndra:dependency")
    }

    @TestCase
    func resolutionDistinguishesMissingDisabledAndWrongComponentOrVersion(): Unit {
        let consumer = dependencyTestDescriptor("consumer", dependencies: "[" + dependencyTestRow("axyndra:dependency") + "]")
        let dependency = dependencyTestDescriptor("dependency")
        @Expect(dependencyError(resolvePluginDependencies(consumer, [])), "plugin.component_dependency_missing")
        @Expect(dependencyError(resolvePluginDependencies(consumer, [PluginDependencyNode(dependency, false)])), "plugin.component_dependency_disabled")
        for (row in [dependencyTestRow("axyndra:dependency", name: "missing"), dependencyTestRow("axyndra:dependency", kind: "tool"),
            dependencyTestRow("axyndra:dependency", range: "[2.0.0,3.0.0)")]) {
            let invalid = dependencyTestDescriptor("consumer", dependencies: "[" + row + "]")
            @Expect(dependencyError(resolvePluginDependencies(invalid, [PluginDependencyNode(dependency, true)])), "plugin.component_dependency_incompatible")
        }
        @Expect(dependencyError(resolvePluginDependencies(consumer, [PluginDependencyNode(dependency, true), PluginDependencyNode(dependency, true)])),
            "plugin.component_dependency_ambiguous")
    }

    @TestCase
    func cyclesAndDepthAreRejectedWithoutAnActivationOrder(): Unit {
        let first = dependencyTestDescriptor("first", dependencies: "[" + dependencyTestRow("axyndra:second") + "]")
        let second = dependencyTestDescriptor("second", dependencies: "[" + dependencyTestRow("axyndra:first") + "]")
        @Expect(dependencyError(resolvePluginDependencies(first, [PluginDependencyNode(first, false), PluginDependencyNode(second, false)])), "plugin.component_dependency_cycle")
        let nodes = ArrayList<PluginDependencyNode>()
        for (index in 0..35) {
            let dependencies = if (index == 34) { "[]" } else { "[" + dependencyTestRow("axyndra:depth-" + (index + 1).toString()) + "]" }
            nodes.add(PluginDependencyNode(dependencyTestDescriptor("depth-" + index.toString(), dependencies: dependencies), true))
        }
        @Expect(dependencyError(resolvePluginDependencies(nodes[0].descriptor, nodes.toArray())), "plugin.component_dependency_depth")
    }

    @TestCase
    func diamondUsesOneExistingDependencyAndPreservesTopologicalOrder(): Unit {
        let common = dependencyTestDescriptor("common")
        let first = dependencyTestDescriptor("first", dependencies: "[" + dependencyTestRow("axyndra:common") + "]")
        let second = dependencyTestDescriptor("second", dependencies: "[" + dependencyTestRow("axyndra:common") + "]")
        let root = dependencyTestDescriptor("consumer", dependencies: "[" + dependencyTestRow("axyndra:first") + "," + dependencyTestRow("axyndra:second") + "]")
        let result = resolvePluginDependencies(root, [PluginDependencyNode(root, false), PluginDependencyNode(second, true), PluginDependencyNode(first, true), PluginDependencyNode(common, true)])
        @Expect(match (result) { case PluginPackageResult.Ok(values) => values.map { value => value.namespace } ==
            ["axyndra:common", "axyndra:first", "axyndra:second", "axyndra:consumer"]; case PluginPackageResult.Err(_) => false })
    }
}
