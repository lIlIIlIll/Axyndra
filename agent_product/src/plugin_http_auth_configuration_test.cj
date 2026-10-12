package agent_product

import agent_domain.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class PluginHttpAuthConfigurationTests {
    @TestCase
    func explicitHeaderPrefixIsFrozenWithoutReadingOrStoringSecret(): Unit {
        let root = pluginContractTemp("http-auth-config")
        try {
            writePluginHttpConfigTest(root, pluginHttpConfigTestDocument(
                injection: "{\"header\":\"Authorization\",\"prefix\":\"Bearer \"}"))
            let configuration = mustPluginHttpConfigTest(root)
            let request = pluginHttpConfigTestRequest()
            @Expect(configuration.bindIntents(pluginHttpConfigTestIntents(request)).isOk())
            let grant = configuration.streamMaintenanceGrants().value().getOrThrow()
            @Expect(lifecycleText(grant.items[0].field("credential_headers").getOrThrow().items[0], "prefix"), "Bearer ")
            @Expect(configuration.resolveCredentials(request).isError())
            Directory.create(root + "/credentials", recursive: true)
            let secret = "prefix-credential-22c9"
            File.writeTo(root + "/credentials/token", secret.toArray())
            let credentials = configuration.resolveCredentials(request).value().getOrThrow()
            @Expect(credentials[0].secret, secret)
            @Expect(credentials[0].headerValue(), "Bearer " + secret)
            @Expect(credentials[0].redactedValues(), [secret, "Bearer " + secret])
            @Expect(pluginHttpCurlArguments(request, credentials).value().getOrThrow().contains("authorization: Bearer " + secret))
            @Expect(!stringifyUnifiedJson(grant).contains(secret))
            @Expect(!stringifyUnifiedJson(configuration.configuration).contains(secret))
            writePluginHttpConfigTest(root, pluginHttpConfigTestDocument())
            @Expect(configuration.stillCurrent().isError())
            @Expect(configuration.resolveCredentials(request).isError())
            let raw = mustPluginHttpConfigTest(root).resolveCredentials(request).value().getOrThrow()
            @Expect(raw[0].headerValue(), secret)
            @Expect(raw[0].redactedValues(), [secret])
        } finally { remove(root, recursive: true) }
    }

    @TestCase
    func headerPrefixRejectsControlTypeAndSizeBeforeReadingCredential(): Unit {
        let root = pluginContractTemp("http-auth-invalid")
        try {
            for (injection in ["{\"header\":\"Authorization\",\"prefix\":null}",
                "{\"header\":\"Authorization\",\"prefix\":4}",
                "{\"header\":\"Authorization\",\"prefix\":\"bad\\r\\n\"}",
                "{\"header\":\"Authorization\",\"prefix\":\"雪\"}",
                "{\"json_pointer\":\"/token\",\"prefix\":\"Bearer \"}",
                "{\"header\":\"Authorization\",\"prefix\":\"" + String.fromUtf8(Array<Byte>(129, repeat: 120u8)) + "\"}"]) {
                writePluginHttpConfigTest(root, pluginHttpConfigTestDocument(injection: injection))
                @Expect(loadPluginHttpConfigTest(root).isError())
            }
            writePluginHttpConfigTest(root, pluginHttpConfigTestDocument(injection: "{\"header\":\"Authorization\",\"prefix\":\"Bearer \"}"))
            Directory.create(root + "/credentials", recursive: true)
            File.writeTo(root + "/credentials/token", Array<Byte>(8192, repeat: 120u8))
            @Expect(mustPluginHttpConfigTest(root).resolveCredentials(pluginHttpConfigTestRequest()).isError())
        } finally { remove(root, recursive: true) }
    }
}
