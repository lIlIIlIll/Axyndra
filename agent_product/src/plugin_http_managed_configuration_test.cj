package agent_product

import agent_domain.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class PluginHttpManagedConfigurationTests {
    @TestCase
    func maintenanceProjectionNeedsNoSecretAndCannotMutateConfigurationOrGrant(): Unit {
        let root = pluginContractTemp("http-maintenance-projection")
        try {
            writePluginHttpConfigTest(root, pluginHttpConfigTestDocument())
            // The referenced token file deliberately does not exist. Merely
            // inspecting the exact approval envelope never resolves a secret.
            let configuration = mustPluginHttpConfigTest(root)
            let original = lifecycleTestRequire(configuration.streamMaintenanceGrants())
            @Expect(original.items.size, 1)
            @Expect(lifecycleText(original.items[0], "url"), "https://api.example.test/search")
            @Expect(lifecycleText(original.items[0], "header_policy"), "http-service-headers/v1")
            let headers = original.items[0].field("credential_headers").getOrThrow()
            @Expect(lifecycleText(headers.items[0], "ref"), "token")
            @Expect(lifecycleText(headers.items[0], "header"), "authorization")
            @Expect(!stringifyUnifiedJson(original).contains("json_pointer") && !stringifyUnifiedJson(original).contains("environment"))
            original.items[0].put("url", textValue("https://attacker.invalid/"))
            let view = configuration.configuration
            view.put("endpoint", textValue("https://attacker.invalid/"))
            @Expect(lifecycleText(configuration.configuration, "endpoint"), "https://api.example.test/search")
            @Expect(lifecycleText(lifecycleTestRequire(configuration.streamMaintenanceGrants()).items[0], "url"), "https://api.example.test/search")
            @Expect(configuration.resolveCredentials(pluginHttpConfigTestRequest()).isError())
        } finally { remove(root, recursive: true) }
    }

    @TestCase
    func maintenanceRejectsChangedOrRemovedOperatorConfigurationWithoutReadingCredentials(): Unit {
        let root = pluginContractTemp("http-maintenance-current")
        try {
            let document = pluginHttpConfigTestDocument()
            writePluginHttpConfigTest(root, document)
            let configuration = mustPluginHttpConfigTest(root)
            @Expect(configuration.streamMaintenanceGrants().isOk())
            writePluginHttpConfigTest(root, document.replace("api.example.test", "other.example.test"))
            @Expect(configuration.streamMaintenanceGrants().isError())
            remove(root + "/plugins/services.json")
            @Expect(configuration.streamMaintenanceGrants().isError())
        } finally { remove(root, recursive: true) }
    }

    @TestCase
    func exactBodyMaintenanceRejectsJsonInjectionWhileLegacyJsonBindingRemainsAvailable(): Unit {
        let root = pluginContractTemp("http-maintenance-header-only")
        try {
            writePluginHttpConfigTest(root, pluginHttpConfigTestDocument(injection: "{\"json_pointer\":\"/api_key\"}"))
            let configuration = mustPluginHttpConfigTest(root)
            let denied = configuration.streamMaintenanceGrants()
            @Expect(denied.isError())
            @Expect(denied.error().getOrThrow().code, "http.stream_body_injection_denied")
            @Expect(configuration.bindIntents(pluginHttpConfigTestIntents(pluginHttpConfigTestRequest())).isOk())
        } finally { remove(root, recursive: true) }
    }
}
