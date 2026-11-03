package agent_product

import agent_domain.*
import std.convert.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class PluginServiceReadOnlyConfigurationTests {
    @TestCase
    func exactOperatorToolsAreFrozenAndConfigurationChangeRevokesBothTransports(): Unit {
        let fixture = LifecycleConfigurationFixture()
        let root = pluginContractTemp("readonly-http-config")
        try {
            let service = fixture.service()
            service.put("read_only_tools", listValue([textValue("echo")]))
            fixture.write(fixture.document(service: Some(service)))
            let configuration = lifecycleTestRequire(fixture.load())
            let grant = lifecycleTestRequire(fixture.bind(configuration))
            @Expect(serviceGrantDeclaresReadOnly(grant.launchPlan, "echo"))
            @Expect(!serviceGrantDeclaresReadOnly(grant.launchPlan, "other"))
            let view = grant.launchPlan
            view.put("read_only_tools", listValue([textValue("other")]))
            @Expect(serviceGrantDeclaresReadOnly(grant.launchPlan, "echo"))
            service.put("read_only_tools", listValue([textValue("other")]))
            fixture.write(fixture.document(service: Some(service)))
            @Expect(configuration.stillCurrent().isError())
            @Expect(grant.stillCurrent().isError())

            let document = parseUnifiedJson(pluginHttpConfigTestDocument())
            let plugin = document.field("plugins").getOrThrow().items[0]
            plugin.put("read_only_tools", listValue([textValue("echo")]))
            writePluginHttpConfigTest(root, stringifyUnifiedJson(document))
            let http = mustPluginHttpConfigTest(root)
            @Expect(http.readOnlyTools, ["echo"])
            let names = http.readOnlyTools
            names[0] = "other"
            @Expect(http.readOnlyTools, ["echo"])
            plugin.put("read_only_tools", listValue([textValue("other")]))
            writePluginHttpConfigTest(root, stringifyUnifiedJson(document))
            @Expect(http.stillCurrent().isError())
        } finally { fixture.close(); remove(root, recursive: true) }
    }

    @TestCase
    func malformedOperatorAssertionsAreRejectedByBothConfigurationLoaders(): Unit {
        let fixture = LifecycleConfigurationFixture()
        let root = pluginContractTemp("readonly-invalid-config")
        try {
            for (invalid in [nullValue(), boolValue(true), textValue("echo"), listValue([integerValue(1)]),
                listValue([textValue("echo"), textValue("echo")]), listValue([textValue("*")]),
                listValue([textValue("foreign/tool")]), listValue([textValue("")]),
                listValue([textValue(String.fromUtf8(Array<Byte>(129, repeat: 120u8)))]),
                listValue(Array<AgentValue>(65, { index => textValue("tool-" + index.toString()) }))]) {
                let service = fixture.service()
                service.put("read_only_tools", invalid)
                fixture.write(fixture.document(service: Some(service)))
                @Expect(fixture.load().isError())
                let document = parseUnifiedJson(pluginHttpConfigTestDocument())
                document.field("plugins").getOrThrow().items[0].put("read_only_tools", invalid)
                writePluginHttpConfigTest(root, stringifyUnifiedJson(document))
                @Expect(loadPluginHttpConfigTest(root).isError())
            }
        } finally { fixture.close(); remove(root, recursive: true) }
    }
}
