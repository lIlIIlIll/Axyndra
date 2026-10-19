package agent_product

import agent_domain.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func lifecycleTestRequire<T>(result: Result<T>): T {
    match (result) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(error.describe())
    }
}

class LifecycleConfigurationFixture {
    let root: String
    let settings: String
    let packageRoot: String
    let workspace: String
    let external: String
    let executable: String
    let namespace = "axyndra:lifecycle-contract"
    let packageDigest = "sha256:" + modelPolicySha256Text("lifecycle-contract-package")

    init() {
        root = Directory.createTemp("/tmp").toString()
        settings = root + "/settings"
        packageRoot = root + "/package"
        workspace = root + "/workspace"
        external = root + "/external"
        executable = packageRoot + "/worker"
        Directory.create(settings + "/plugins", recursive: true)
        Directory.create(packageRoot)
        Directory.create(workspace)
        Directory.create(external)
        File.writeTo(executable, "#!/bin/sh\nexit 0\n".toArray())
        let _ = FileInfo(executable).setExecutable(true)
        if (!FileInfo(executable).canExecute()) { throw IllegalStateException("lifecycle fixture executable permission unavailable") }
    }

    func service(): AgentValue {
        objectValue([
            ValueField("id", textValue("stdio")), ValueField("executable", textValue(executable)),
            ValueField("arguments", listValue([textValue("--stdio"), textValue("")])),
            ValueField("read_only_mounts", listValue([])), ValueField("workspace_mode", textValue("isolated_readonly")),
            ValueField("network", networkPolicyCanonicalValue(NetworkPolicy(NetworkPolicyMode.Denied))),
            ValueField("resources", objectValue([
                ValueField("max_output_bytes", integerValue(1048576)), ValueField("address_space_bytes", integerValue(536870912)),
                ValueField("file_size_bytes", integerValue(1048576)), ValueField("open_files", integerValue(64)),
                ValueField("processes", integerValue(8)), ValueField("cpu_seconds", integerValue(10))])),
            ValueField("lifetime_ms", integerValue(10000)), ValueField("max_input_bytes", integerValue(8192)),
            ValueField("max_output_bytes", integerValue(1048576)), ValueField("startup", objectValue([
                ValueField("timeout_ms", integerValue(1000)), ValueField("max_input_bytes", integerValue(4096)),
                ValueField("max_output_bytes", integerValue(4096)), ValueField("max_writes", integerValue(4))])),
            ValueField("environment", objectValue([])), ValueField("credential_refs", listValue([]))
        ])
    }

    func document(service!: ?AgentValue = None): AgentValue {
        objectValue([ValueField("version", integerValue(1)), ValueField("plugins", listValue([objectValue([
            ValueField("namespace", textValue(namespace)), ValueField("package_digest", textValue(packageDigest)),
            ValueField("configuration", objectValue([ValueField("protocol", textValue("fixture-stdio"))])),
            ValueField("max_instances", integerValue(2)),
            ValueField("services", listValue([match (service) { case Some(value) => value; case None => this.service() }]))
        ])]))])
    }
    func write(document: AgentValue): Unit {
        File.writeTo(settings + "/plugins/lifecycle.json", stringifyUnifiedJson(document).toArray())
    }
    func load(): Result<ProductPluginLifecycleConfiguration> {
        loadPluginLifecycleConfiguration(settings, namespace, packageDigest, packageRoot)
    }
    func bind(configuration: ProductPluginLifecycleConfiguration,
        limits!: ExecutionResourceLimits = ExecutionResourceLimits()): Result<ProductPluginLifecycleLaunchGrant> {
        configuration.bindService("stdio", ThreadId("target-thread"), "host-minted-instance", workspace, limits,
            modelPolicySha256Text("fixture-host-permission-domain"))
    }
    func close(): Unit { remove(root, recursive: true) }
}

@Test
class PluginLifecycleConfigurationTests {
    @TestCase
    func missingAndMismatchedBindingsNeverProduceLaunchGrant(): Unit {
        let fixture = LifecycleConfigurationFixture()
        try {
            @Expect(fixture.load().isError())
            let document = fixture.document()
            fixture.write(document)
            @Expect(loadPluginLifecycleConfiguration(fixture.settings, "axyndra:other", fixture.packageDigest,
                fixture.packageRoot).isError())
            @Expect(loadPluginLifecycleConfiguration(fixture.settings, fixture.namespace,
                "sha256:" + modelPolicySha256Text("different-package"), fixture.packageRoot).isError())
            @Expect(loadPluginLifecycleConfiguration(fixture.settings, fixture.namespace,
                modelPolicySha256Text("lifecycle-contract-package"), fixture.packageRoot).isError())
            let config = lifecycleTestRequire(fixture.load())
            @Expect(config.digest, modelPolicySha256Text(stringifyUnifiedJson(document)))
            @Expect(config.bindService("not-granted", ThreadId("target-thread"), "instance", fixture.workspace,
                ExecutionResourceLimits(), modelPolicySha256Text("fixture-host-permission-domain")).isError())
            @Expect(config.bindService("stdio", ThreadId("target-thread"), "forged/instance", fixture.workspace,
                ExecutionResourceLimits(), modelPolicySha256Text("fixture-host-permission-domain")).isError())
            for (domain in ["", "*", "ABCDEF", "sha256:" + modelPolicySha256Text("wrong-shape")]) {
                @Expect(config.bindService("stdio", ThreadId("target-thread"), "instance", fixture.workspace,
                    ExecutionResourceLimits(), domain).isError())
            }
            let first = lifecycleTestRequire(fixture.bind(config))
            let second = lifecycleTestRequire(config.bindService("stdio", ThreadId("target-thread"),
                "host-minted-instance", fixture.workspace, ExecutionResourceLimits(), modelPolicySha256Text("another-domain")))
            @Expect(first.digest != second.digest)
            @Expect(first.launchPlan.field("permission_domain").getOrThrow().text,
                modelPolicySha256Text("fixture-host-permission-domain"))
            @Expect(fixture.bind(config).isOk())
        } finally { fixture.close() }
    }

    @TestCase
    func strictSchemaRejectsVersionsUnknownFieldsDuplicateIdsAndSecrets(): Unit {
        let fixture = LifecycleConfigurationFixture()
        try {
            let good = stringifyUnifiedJson(fixture.document())
            for (text in [good.replace("\"version\":1", "\"version\":2"),
                good.replace("\"version\":1", "\"version\":1,\"grant\":true"),
                good.replace("\"max_instances\":2", "\"max_instances\":0"),
                good.replace("\"max_instances\":2", "\"max_instances\":33"),
                good.replace("\"id\":\"stdio\"", "\"id\":\"stdio\",\"source\":\"host_service\""),
                good.replace("sha256:", "SHA256:"), good.replace(fixture.namespace, "*"),
                good.replace("\"environment\":{}", "\"environment\":{\"TOKEN\":\"never-in-error-772\"}"),
                good.replace("\"credential_refs\":[]", "\"credential_refs\":[\"secret-ref\"]")]) {
                File.writeTo(fixture.settings + "/plugins/lifecycle.json", text.toArray())
                let result = fixture.load()
                @Expect(result.isError())
                if (result.isError()) { @Expect(!result.error().getOrThrow().describe().contains("never-in-error-772")) }
            }
            let secret = fixture.service()
            secret.put("environment", objectValue([ValueField("PATH", textValue("EXPLICIT_SOURCE"))]))
            fixture.write(fixture.document(service: Some(secret)))
            @Expect(fixture.load().error().getOrThrow().code, "plugin.lifecycle_environment_invalid")
            let duplicate = fixture.document()
            let plugin = duplicate.field("plugins").getOrThrow().items[0]
            plugin.put("services", listValue([fixture.service(), fixture.service()]))
            fixture.write(duplicate)
            @Expect(fixture.load().isError())
            let duplicatePlugin = fixture.document()
            let first = duplicatePlugin.field("plugins").getOrThrow().items[0]
            duplicatePlugin.put("plugins", listValue([first, first]))
            fixture.write(duplicatePlugin)
            @Expect(fixture.load().isError())
            File.writeTo(fixture.settings + "/plugins/lifecycle.json", Array<Byte>(262145, repeat: 32u8))
            @Expect(fixture.load().error().getOrThrow().code, "plugin.lifecycle_configuration_limit")
        } finally { fixture.close() }
    }

    @TestCase
    func launchPlanFreezesActualExecutableHostIdentityAndDefensiveCopies(): Unit {
        let fixture = LifecycleConfigurationFixture()
        try {
            let authored = fixture.document()
            fixture.write(authored)
            let config = lifecycleTestRequire(fixture.load())
            let grant = lifecycleTestRequire(fixture.bind(config))
            let digest = grant.digest
            let plan = grant.launchPlan
            @Expect(plan.field("executable").getOrThrow().text, canonicalize(Path(fixture.executable)).toString())
            @Expect(plan.field("executable_sha256").getOrThrow().text, modelPolicySha256Text("#!/bin/sh\nexit 0\n"))
            @Expect(plan.field("thread_id").getOrThrow().text, "target-thread")
            @Expect(plan.field("instance_identity").getOrThrow().text, "host-minted-instance")
            @Expect(plan.field("configuration_digest").getOrThrow().text, config.digest)
            config.configuration.put("protocol", textValue("mutated"))
            plan.field("arguments").getOrThrow().add(textValue("--mutated"))
            plan.put("executable", textValue("/unauthorized"))
            plan.field("resources").getOrThrow().put("processes", integerValue(1000))
            authored.field("plugins").getOrThrow().items[0].field("configuration").getOrThrow().put("protocol", textValue("changed-input"))
            @Expect(config.configuration.field("protocol").getOrThrow().text, "fixture-stdio")
            @Expect(grant.launchPlan.field("arguments").getOrThrow().items[0].text, "--stdio")
            @Expect(grant.launchPlan.field("arguments").getOrThrow().items.size, 2)
            @Expect(grant.digest, digest)
            let request = lifecycleTestRequire(grant.processRequest(OperationId("actual-start-operation")))
            @Expect(request.operationId.value, "actual-start-operation")
            @Expect(request.executable, canonicalize(Path(fixture.executable)).toString())
            @Expect(request.arguments, ["--stdio", ""])
            @Expect(request.environmentAllowlist.isEmpty() && request.secretEnvironmentAllowlist.isEmpty())
            @Expect(request.networkPolicy.mode == NetworkPolicyMode.Denied && request.sandboxMode == ProcessSandboxMode.IsolatedReadOnly)
            @Expect(grant.processRequest(OperationId("process")).isError())
        } finally { fixture.close() }
    }

    @TestCase
    func configurationRemovalChangesAndSymlinkMetadataRevokeExistingBinding(): Unit {
        let fixture = LifecycleConfigurationFixture()
        try {
            let document = fixture.document()
            fixture.write(document)
            let config = lifecycleTestRequire(fixture.load())
            let grant = lifecycleTestRequire(fixture.bind(config))
            File.writeTo(fixture.settings + "/plugins/lifecycle.json", (stringifyUnifiedJson(document) + "\n").toArray())
            @Expect(config.stillCurrent().isError() && grant.stillCurrent().isError())
            @Expect(grant.processRequest(OperationId("actual-start-operation")).isError())
            fixture.write(document)
            remove(fixture.settings + "/plugins/lifecycle.json")
            @Expect(config.stillCurrent().isError())
            File.writeTo(fixture.external + "/lifecycle.json", stringifyUnifiedJson(document).toArray())
            SymbolicLink.create(fixture.settings + "/plugins/lifecycle.json", to: fixture.external + "/lifecycle.json")
            @Expect(fixture.load().isError())
            remove(fixture.settings + "/plugins/lifecycle.json")
            remove(fixture.settings + "/plugins")
            SymbolicLink.create(fixture.settings + "/plugins", to: fixture.external)
            @Expect(fixture.load().isError())
        } finally { fixture.close() }
    }

    @TestCase
    func executableHashIsBoundedStreamedAndRecheckedAlongWithSymlinkResolution(): Unit {
        let fixture = LifecycleConfigurationFixture()
        try {
            let content = String.fromUtf8(Array<Byte>(65539, repeat: 97u8))
            File.writeTo(fixture.executable, content.toArray())
            let _ = FileInfo(fixture.executable).setExecutable(true)
            @Expect(lifecycleExecutable(fixture.executable).digest, modelPolicySha256Text(content))
            let overLimit = try { let _ = lifecycleExecutable(fixture.executable, maximumBytes: 65536); false }
                catch (error: Exception) { error.message == "plugin.lifecycle_executable_limit" }
            @Expect(overLimit)
            let link = fixture.packageRoot + "/entry"
            SymbolicLink.create(link, to: fixture.executable)
            let service = fixture.service(); service.put("executable", textValue(link))
            fixture.write(fixture.document(service: Some(service)))
            let grant = lifecycleTestRequire(fixture.bind(lifecycleTestRequire(fixture.load())))
            @Expect(grant.stillCurrent().isOk())
            File.writeTo(fixture.executable, content.replace("a", "b").toArray())
            @Expect(grant.stillCurrent().isError())
            File.writeTo(fixture.executable, content.toArray())
            let second = fixture.packageRoot + "/other-worker"
            File.writeTo(second, content.toArray()); let _ = FileInfo(second).setExecutable(true)
            remove(link); SymbolicLink.create(link, to: second)
            @Expect(grant.stillCurrent().isError())
            let _ = FileInfo(second).setExecutable(false)
            @Expect(fixture.bind(lifecycleTestRequire(fixture.load())).isError())
        } finally { fixture.close() }
    }

    @TestCase
    func explicitMountsNeverWidenWorkspaceOrImplicitlyExposeExecutableParent(): Unit {
        let fixture = LifecycleConfigurationFixture()
        try {
            let worker = fixture.external + "/worker"
            File.writeTo(worker, "#!/bin/sh\nexit 0\n".toArray()); let _ = FileInfo(worker).setExecutable(true)
            let service = fixture.service(); service.put("executable", textValue(worker))
            fixture.write(fixture.document(service: Some(service)))
            @Expect(fixture.bind(lifecycleTestRequire(fixture.load())).error().getOrThrow().code,
                "plugin.lifecycle_executable_not_mounted")
            service.put("read_only_mounts", listValue([textValue(worker)]))
            fixture.write(fixture.document(service: Some(service)))
            let grant = lifecycleTestRequire(fixture.bind(lifecycleTestRequire(fixture.load())))
            @Expect(grant.launchPlan.field("read_only_mounts").getOrThrow().items.size, 1)
            @Expect(grant.launchPlan.field("read_only_mounts").getOrThrow().items[0].text, worker)
            service.put("read_only_mounts", listValue([textValue("/")]))
            fixture.write(fixture.document(service: Some(service)))
            @Expect(fixture.bind(lifecycleTestRequire(fixture.load())).isError())
            service.put("workspace_mode", textValue("workspace_readwrite"))
            service.put("read_only_mounts", listValue([textValue(fixture.workspace)]))
            fixture.write(fixture.document(service: Some(service)))
            @Expect(fixture.bind(lifecycleTestRequire(fixture.load())).error().getOrThrow().code, "plugin.lifecycle_mount_overlap")
            service.put("read_only_mounts", listValue([textValue(worker)]))
            fixture.write(fixture.document(service: Some(service)))
            let writable = lifecycleTestRequire(fixture.bind(lifecycleTestRequire(fixture.load())))
            @Expect(writable.launchPlan.field("cwd").getOrThrow().text, fixture.workspace)
            @Expect(writable.launchPlan.field("read_only_mounts").getOrThrow().items.size, 2)
        } finally { fixture.close() }
    }

    @TestCase
    func normalizedNetworkAndPositiveResourceCeilingsRemainOperatorBound(): Unit {
        let fixture = LifecycleConfigurationFixture()
        try {
            let service = fixture.service()
            let network = NetworkPolicy(NetworkPolicyMode.Mediated,
                egress: [NetworkEgressRule("127.0.0.1", 8080u16, privateAddresses: ["127.0.0.1"])])
            service.put("network", networkPolicyCanonicalValue(network))
            fixture.write(fixture.document(service: Some(service)))
            let configuration = lifecycleTestRequire(fixture.load())
            let grant = lifecycleTestRequire(fixture.bind(configuration, limits: ExecutionResourceLimits(
                maxOutputBytes: 8192, addressSpaceBytes: 134217728, openFiles: 32, processes: 4, cpuSeconds: 5)))
            let request = lifecycleTestRequire(grant.processRequest(OperationId("real-start")))
            @Expect(request.processLimits.maxOutputBytes, 8192)
            @Expect(request.processLimits.addressSpaceBytes, 134217728)
            @Expect(request.processLimits.openFiles, 32)
            @Expect(request.networkPolicy.mode == NetworkPolicyMode.Mediated && request.networkPolicy.egress.size == 1)
            @Expect(request.networkPolicy.egress[0].privateAddresses, ["127.0.0.1"])
            @Expect(fixture.bind(configuration, limits: ExecutionResourceLimits(maxOutputBytes: 1024))
                .error().getOrThrow().code, "plugin.lifecycle_host_ceiling_insufficient")
            let hostService = fixture.service()
            hostService.put("network", networkPolicyCanonicalValue(NetworkPolicy(NetworkPolicyMode.HostNetwork)))
            fixture.write(fixture.document(service: Some(hostService)))
            let hostGrant = lifecycleTestRequire(fixture.bind(lifecycleTestRequire(fixture.load())))
            @Expect(lifecycleTestRequire(hostGrant.processRequest(OperationId("host-start"))).networkPolicy.mode ==
                NetworkPolicyMode.HostNetwork)
            @Expect(networkPolicyCapabilityResources(NetworkPolicy(NetworkPolicyMode.HostNetwork)), ["[\"host\"]"])
            for (network in [NetworkPolicy(NetworkPolicyMode.Mediated, publish: [NetworkPublishRule(12345u16, 12345u16)])]) {
                let invalid = fixture.service(); invalid.put("network", networkPolicyCanonicalValue(network))
                fixture.write(fixture.document(service: Some(invalid)))
                @Expect(fixture.load().error().getOrThrow().code, "plugin.lifecycle_network_unsupported")
            }
            for (field in ["max_input_bytes", "max_output_bytes", "lifetime_ms"]) {
                let invalid = fixture.service(); invalid.put(field, integerValue(Int64.Max))
                fixture.write(fixture.document(service: Some(invalid)))
                @Expect(fixture.load().isError())
            }
            for (field in ["max_output_bytes", "address_space_bytes", "file_size_bytes", "open_files", "processes", "cpu_seconds"]) {
                for (bad in [0, Int64.Max]) {
                    let invalid = fixture.service(); invalid.field("resources").getOrThrow().put(field, integerValue(bad))
                    fixture.write(fixture.document(service: Some(invalid)))
                    @Expect(fixture.load().isError())
                }
            }
            let oversizedWindow = fixture.service()
            oversizedWindow.field("startup").getOrThrow().put("timeout_ms", integerValue(10001))
            fixture.write(fixture.document(service: Some(oversizedWindow)))
            @Expect(fixture.load().isError())
        } finally { fixture.close() }
    }
}
