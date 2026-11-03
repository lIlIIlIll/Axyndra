package agent_product

import agent_domain.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func pluginHttpConfigTestDocument(source!: String = "{\"file\":\"token\"}",
    injection!: String = "{\"header\":\"Authorization\"}"): String {
    "{\"version\":1,\"plugins\":[{\"namespace\":\"axyndra:http-fixture\",\"package_digest\":\"" +
        pluginHttpConfigTestPackageDigest() + "\",\"configuration\":{\"endpoint\":\"https://api.example.test/search\"}," +
        "\"requests\":[{\"url\":\"https://api.example.test/search\",\"methods\":[\"GET\",\"POST\"],\"private_addresses\":[],\"credential_refs\":[\"token\"]}]," +
        "\"credentials\":[{\"ref\":\"token\",\"source\":" + source + ",\"injection\":" + injection + "}]}]}"
}

func writePluginHttpConfigTest(root: String, document: String): Unit {
    if (!exists(Path(root + "/plugins"))) {
        Directory.create(root + "/plugins", recursive: true)
    }
    File.writeTo(root + "/plugins/services.json", document.toArray())
}

func loadPluginHttpConfigTest(root: String): Result<ProductPluginHttpConfiguration> {
    loadPluginHttpConfiguration(root, "axyndra:http-fixture", pluginHttpConfigTestPackageDigest())
}

func pluginHttpConfigTestPackageDigest(): String {
    "sha256:" + modelPolicySha256Text("http-fixture-package")
}

func mustPluginHttpConfigTest(root: String): ProductPluginHttpConfiguration {
    match (loadPluginHttpConfigTest(root)) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
}

func pluginHttpConfigTestRequest(method!: String = "POST", url!: String = "https://api.example.test/search",
    ref!: String = "token", body!: AgentValue = objectValue([]), headers!: AgentValue = objectValue([])): AgentValue {
    objectValue([
        ValueField("method", textValue(method)), ValueField("url", textValue(url)),
        ValueField("query", objectValue([])), ValueField("headers", headers),
        ValueField("json_body", if (method == "GET") { nullValue() } else { body }),
        ValueField("credential_refs", listValue([textValue(ref)])), ValueField("timeout_ms", integerValue(1000))
    ])
}

func pluginHttpConfigTestIntents(request: AgentValue): AgentValue {
    objectValue([ValueField("intents", listValue([objectValue([
        ValueField("id", textValue("request-1")), ValueField("request", request)
    ])]))])
}

@Test
class PluginHttpConfigurationTests {
    @TestCase
    func missingAndMismatchedOperatorBindingsNeverGrantAuthority(): Unit {
        let root = pluginContractTemp("http-config-binding")
        @Expect(loadPluginHttpConfigTest(root).isError())
        let document = pluginHttpConfigTestDocument()
        writePluginHttpConfigTest(root, document)
        @Expect(loadPluginHttpConfiguration(root, "axyndra:other", pluginHttpConfigTestPackageDigest()).isError())
        @Expect(loadPluginHttpConfiguration(root, "axyndra:http-fixture", "sha256:" + modelPolicySha256Text("changed-package")).isError())
        @Expect(loadPluginHttpConfiguration(root, "axyndra:http-fixture", modelPolicySha256Text("http-fixture-package")).isError())
        let config = mustPluginHttpConfigTest(root)
        @Expect(config.digest, modelPolicySha256Text(document))
        @Expect(config.namespace, "axyndra:http-fixture")
        @Expect(config.packageDigest, pluginHttpConfigTestPackageDigest())
        @Expect(config.bindIntents(pluginHttpConfigTestIntents(pluginHttpConfigTestRequest())).isOk())
        for (url in ["https://api.example.test/search/extra", "https://other.example.test/search",
            "https://api.example.test/search?token=x"]) {
            @Expect(config.bindIntents(pluginHttpConfigTestIntents(pluginHttpConfigTestRequest(url: url))).isError())
        }
        @Expect(config.bindIntents(pluginHttpConfigTestIntents(pluginHttpConfigTestRequest(ref: "foreign"))).isError())
        writePluginHttpConfigTest(root, document.replace("[\"GET\",\"POST\"]", "[\"GET\"]"))
        let readOnly = mustPluginHttpConfigTest(root)
        @Expect(readOnly.bindIntents(pluginHttpConfigTestIntents(pluginHttpConfigTestRequest())).isError())
        @Expect(readOnly.bindIntents(pluginHttpConfigTestIntents(pluginHttpConfigTestRequest(method: "GET"))).isOk())
        writePluginHttpConfigTest(root, document.replace("https://api.example.test/search", "http://127.0.0.1:8080/search")
            .replace("\"private_addresses\":[]", "\"private_addresses\":[\"127.0.0.1\"]"))
        let local = mustPluginHttpConfigTest(root).bindIntents(pluginHttpConfigTestIntents(
            pluginHttpConfigTestRequest(url: "http://127.0.0.1:8080/search"))).value().getOrThrow()
        let policy = httpIntentPolicy(local[0]).value().getOrThrow()
        @Expect(policy.mode == NetworkPolicyMode.Mediated && policy.egress.size == 1)
        @Expect(policy.egress[0].privateAddresses, ["127.0.0.1"])
    }

    @TestCase
    func strictConfigurationRejectsUnknownFieldsVersionsAndWildcardGrants(): Unit {
        let root = pluginContractTemp("http-config-shape")
        let document = pluginHttpConfigTestDocument()
        for (invalid in [document.replace("\"version\":1", "\"version\":2"),
            document.replace("\"version\":1", "\"version\":1,\"extra\":true"),
            document.replace("\"configuration\":", "\"surprise\":true,\"configuration\":"),
            document.replace("axyndra:http-fixture", "*"),
            document.replace("sha256:", ""),
            document.replace("sha256:", "SHA256:"),
            document.replace(pluginHttpConfigTestPackageDigest(), "sha256:" + modelPolicySha256Text("http-fixture-package").toAsciiUpper()),
            document.replace("[\"GET\",\"POST\"]", "[\"DELETE\"]"),
            document.replace("\"private_addresses\":[]", "\"private_addresses\":[\"not-an-ip\"]"),
            document.replace("\"credential_refs\":[\"token\"]", "\"credential_refs\":[\"missing\"]"),
            pluginHttpConfigTestDocument(source: "{\"file\":\"token\",\"environment\":\"TOKEN\"}"),
            pluginHttpConfigTestDocument(injection: "{\"header\":\"Host\"}"),
            pluginHttpConfigTestDocument(injection: "{\"header\":\"Proxy-Authorization\"}")]) {
            writePluginHttpConfigTest(root, invalid)
            @Expect(loadPluginHttpConfigTest(root).isError())
        }
        writePluginHttpConfigTest(root, document)
        let config = mustPluginHttpConfigTest(root)
        @Expect(config.bindIntents(objectValue([ValueField("intents", listValue([])),
            ValueField("source", textValue("plugin-forgery"))])).isError())
        let intent = pluginHttpConfigTestIntents(pluginHttpConfigTestRequest()).field("intents").getOrThrow().items[0]
        @Expect(config.bindIntents(objectValue([ValueField("intents", listValue([intent, intent]))])).isError())
        writePluginHttpConfigTest(root, String.fromUtf8(Array<Byte>(262145, repeat: 32u8)))
        @Expect(loadPluginHttpConfigTest(root).isError())
    }

    @TestCase
    func preparationDoesNotReadSecretsAndExecutionAllowsShortValuesWithoutPersistingThem(): Unit {
        let root = pluginContractTemp("http-config-late-secret")
        writePluginHttpConfigTest(root, pluginHttpConfigTestDocument())
        let config = mustPluginHttpConfigTest(root)
        let request = pluginHttpConfigTestRequest()
        let bound = config.bindIntents(pluginHttpConfigTestIntents(request))
        @Expect(bound.isOk())
        @Expect(config.resolveCredentials(request).isError())
        Directory.create(root + "/credentials", recursive: true)
        File.writeTo(root + "/credentials/token", "x".toArray())
        let values = config.resolveCredentials(request).value().getOrThrow()
        @Expect(values.size, 1)
        @Expect(values[0].ref, "token")
        @Expect(values[0].secret, "x")
        @Expect(values[0].header, "authorization")
        @Expect(values[0].jsonPointer, "")
        let secret = "SECRET-SHOULD-NOT-ENTER-PLAN-73829"
        File.writeTo(root + "/credentials/token", secret.toArray())
        @Expect(config.resolveCredentials(request).value().getOrThrow()[0].secret, secret)
        @Expect(!canonicalAgentValue(listValue(bound.value().getOrThrow())).contains(secret))
        @Expect(!canonicalAgentValue(config.configuration).contains(secret))
        for (invalid in ["", "bad\rvalue", "bad\nvalue", "bad\u{0000}value", String.fromUtf8(Array<Byte>(8193, repeat: 120u8))]) {
            File.writeTo(root + "/credentials/token", invalid.toArray())
            let rejected = config.resolveCredentials(request)
            @Expect(rejected.isError())
            if (invalid.size > 4) { @Expect(!rejected.error().getOrThrow().describe().contains(invalid)) }
        }
    }

    @TestCase
    func credentialPathsRejectTraversalAndSymlinkComponentsAtResolution(): Unit {
        let root = pluginContractTemp("http-config-path")
        for (path in ["../outside", "/tmp/secret", "a/../token", "a//token", "C:/token"]) {
            writePluginHttpConfigTest(root, pluginHttpConfigTestDocument(source: "{\"file\":\"" + path + "\"}"))
            @Expect(loadPluginHttpConfigTest(root).isError())
        }
        writePluginHttpConfigTest(root, pluginHttpConfigTestDocument())
        Directory.create(root + "/credentials", recursive: true)
        File.writeTo(root + "/outside", "outside-secret".toArray())
        SymbolicLink.create(root + "/credentials/token", to: root + "/outside")
        let config = mustPluginHttpConfigTest(root)
        @Expect(config.resolveCredentials(pluginHttpConfigTestRequest()).isError())
        Directory.create(root + "/elsewhere", recursive: true)
        File.writeTo(root + "/elsewhere/token", "parent-link-secret".toArray())
        SymbolicLink.create(root + "/credentials/linked", to: root + "/elsewhere")
        writePluginHttpConfigTest(root, pluginHttpConfigTestDocument(source: "{\"file\":\"linked/token\"}"))
        @Expect(mustPluginHttpConfigTest(root).resolveCredentials(pluginHttpConfigTestRequest()).isError())
    }

    @TestCase
    func injectionLocationsAreOperatorOwnedAndNeverOverwriteRequestData(): Unit {
        let root = pluginContractTemp("http-config-injection")
        for (pointer in ["", "/", "/a/b", "/bad~2", "/bad~"]) {
            writePluginHttpConfigTest(root, pluginHttpConfigTestDocument(injection: "{\"json_pointer\":\"" + pointer + "\"}"))
            @Expect(loadPluginHttpConfigTest(root).isError())
        }
        writePluginHttpConfigTest(root, pluginHttpConfigTestDocument(injection: "{\"json_pointer\":\"/api~1key\"}"))
        let config = mustPluginHttpConfigTest(root)
        @Expect(pluginHttpJsonPointerField("/api~1key").value().getOrThrow(), "api/key")
        @Expect(config.bindIntents(pluginHttpConfigTestIntents(pluginHttpConfigTestRequest())).isOk())
        @Expect(config.bindIntents(pluginHttpConfigTestIntents(pluginHttpConfigTestRequest(method: "GET"))).isError())
        @Expect(config.bindIntents(pluginHttpConfigTestIntents(pluginHttpConfigTestRequest(body:
            objectValue([ValueField("api/key", nullValue())])))).isError())
        writePluginHttpConfigTest(root, pluginHttpConfigTestDocument(injection: "{\"header\":\"X-Api-Key\"}"))
        @Expect(mustPluginHttpConfigTest(root).bindIntents(pluginHttpConfigTestIntents(pluginHttpConfigTestRequest(headers:
            objectValue([ValueField("X-API-KEY", textValue("plugin-value"))])))).isError())
    }

    @TestCase
    func operatorFileRevocationAndExplicitEnvironmentReferencesRemainFailClosed(): Unit {
        let root = pluginContractTemp("http-config-revocation")
        let variable = "AXYNDRA_HTTP_CONFIGURATION_TEST_TOKEN"
        let previous = getVariable(variable)
        removeVariable(variable)
        try {
            let document = pluginHttpConfigTestDocument(source: "{\"environment\":\"" + variable + "\"}")
            writePluginHttpConfigTest(root, document)
            let config = mustPluginHttpConfigTest(root)
            let request = pluginHttpConfigTestRequest()
            @Expect(config.bindIntents(pluginHttpConfigTestIntents(request)).isOk())
            @Expect(config.resolveCredentials(request).isError())
            setVariable(variable, "t")
            @Expect(config.resolveCredentials(request).value().getOrThrow()[0].secret, "t")
            File.writeTo(root + "/plugins/services.json", (document + "\n").toArray())
            @Expect(config.stillCurrent().isError())
            @Expect(config.bindIntents(pluginHttpConfigTestIntents(request)).isError())
            @Expect(config.resolveCredentials(request).isError())
        } finally {
            match (previous) { case Some(value) => setVariable(variable, value); case None => removeVariable(variable) }
        }
    }
}
