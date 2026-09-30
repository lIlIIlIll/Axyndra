package agent_product

import agent_core.*
import agent_extension_runtime.*
import agent_domain.*
import agent_runtime.*
import agent_skills.*
import tool_runtime.*
import yjson_support.*
import std.fs.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import std.time.*
import process4cj as process

class DelayedPiServiceObserver <: JavaScriptHostObserver {
    private let markerPath: String

    init(markerPath: String) { this.markerPath = markerPath }

    public func onProgress(
        invocationId: String,
        progressJson: String
    ): JavaScriptHostResult<Unit> {
        let _ = invocationId
        let _ = progressJson
        JavaScriptHostResult.Ok(())
    }

    public func onServiceRequest(
        invocationId: String,
        requestId: String,
        service: String,
        argumentsJson: String
    ): JavaScriptHostResult<String> {
        File.writeTo(markerPath, (invocationId + ":" + requestId + ":" + service + ":" + argumentsJson).toArray())
        sleep(Duration.millisecond * 250)
        JavaScriptHostResult.Ok("{\"output\":{\"exit_code\":0,\"stdout\":\"late\",\"stderr\":\"\",\"timed_out\":false}}")
    }
}


class PiUiRecordingObserver <: JavaScriptHostObserver {
    private let markerPath: String

    init(markerPath: String) { this.markerPath = markerPath }

    public func onProgress(
        invocationId: String,
        progressJson: String
    ): JavaScriptHostResult<Unit> {
        let _ = invocationId
        let _ = progressJson
        JavaScriptHostResult.Ok(())
    }

    public func onServiceRequest(
        invocationId: String,
        requestId: String,
        service: String,
        argumentsJson: String
    ): JavaScriptHostResult<String> {
        let _ = invocationId
        let previous = if (exists(Path(markerPath))) {
            String.fromUtf8(File.readFrom(Path(markerPath)))
        } else {
            ""
        }
        File.writeTo(markerPath, (previous + service + ":" + requestId + ":" + argumentsJson + "\n").toArray())
        match (service) {
            case "ui.notify" => JavaScriptHostResult.Ok("{\"accepted\":true}")
            case "ui.select" => JavaScriptHostResult.Ok("{\"value\":\"B\"}")
            case "ui.confirm" => JavaScriptHostResult.Ok("{\"confirmed\":true}")
            case _ => JavaScriptHostResult.Err(JavaScriptHostError(
                "extension.service_unsupported", "unexpected test UI service"
            ))
        }
    }
}

class PiProgressMarkerObserver <: JavaScriptHostObserver {
    private let markerPath: String

    init(markerPath: String) { this.markerPath = markerPath }

    public func onProgress(
        invocationId: String,
        progressJson: String
    ): JavaScriptHostResult<Unit> {
        let _ = invocationId
        File.writeTo(markerPath, progressJson.toArray())
        JavaScriptHostResult.Ok(())
    }

    public func onServiceRequest(
        invocationId: String,
        requestId: String,
        service: String,
        argumentsJson: String
    ): JavaScriptHostResult<String> {
        let _ = invocationId
        let _ = requestId
        let _ = service
        let _ = argumentsJson
        JavaScriptHostResult.Err(JavaScriptHostError(
            "extension.service_unsupported", "no test service is configured"
        ))
    }
}
class AcceptingPluginSignatureVerifier <: ExtensionPackageSignatureVerifier {
    public func verify(_manifest: SignedExtensionPackageManifest): Bool {
        let _ = _manifest
        true
    }
}
class CodexHookToolRecorder <: ToolExecutor {
    public let invocations = ArrayList<String>()

    public func execute(
        _context: ToolInvocationContext,
        prepared: PreparedToolInvocation
    ): Result<ToolResult> {
        invocations.add(
            prepared.call.callId + "|" + prepared.call.name + "|" +
                canonicalAgentValue(prepared.call.arguments)
        )
        Result.Ok(ToolResult(prepared.call.callId, textValue("executed")))
    }
}

@Test
class PluginRuntimeContractTests {
    @TestCase
    func localImportWritesPinnedStaticSnapshotWithoutExecutingPackage(): Unit {
        let root = pluginContractTemp("local")
        let settings = pluginContractTemp("local-settings")
        Directory.create(root + "/skills/demo/references", recursive: true)
        Directory.create(root + "/skills/demo/scripts", recursive: true)
        Directory.create(root + "/skills/demo/assets", recursive: true)
        File.writeTo(root + "/skills/demo/references/context.md", "Reference v1".toArray())
        File.writeTo(root + "/skills/demo/scripts/check.sh", "echo checked".toArray())
        File.writeTo(root + "/skills/demo/assets/fixture.txt", "asset v1".toArray())
        Directory.create(root + "/extensions", recursive: true)
        Directory.create(root + "/hooks", recursive: true)
        let executionMarker = pluginContractTemp("package-code-executed")
        let sideEffect = "const fs=require('node:fs');fs.writeFileSync(\"" + executionMarker + "\",\"executed\");"
        File.writeTo(root + "/extensions/index.js", sideEffect.toArray())
        File.writeTo(root + "/hooks/index.js", sideEffect.toArray())
        File.writeTo(root + "/package.json", "{\"name\":\"local-plugin\",\"version\":\"1.0.0\",\"pi\":{\"skills\":[\"skills\"],\"extensions\":[\"extensions/index.js\"],\"hooks\":[\"hooks/index.js\"]},\"scripts\":{\"postinstall\":\"touch marker\"}}".toArray())
        let runtime = ProductPluginRuntime(settings, root)
        let imported = runtime.importLocal(root)
        @Expect(imported.isOk(), true)
        @Expect(exists(Path(settings + "/plugins/lock.jsonl")), true)
        let record = match (imported) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        @Expect(record.descriptor.root != root, true)
        @Expect(exists(Path(record.descriptor.root + "/package.json")), true)
        @Expect(exists(Path(record.descriptor.root + "/skills/demo/references/context.md")), true)
        @Expect(exists(Path(record.descriptor.root + "/skills/demo/scripts/check.sh")), true)
        @Expect(exists(Path(record.descriptor.root + "/skills/demo/assets/fixture.txt")), true)
        @Expect(exists(Path(root + "/marker")), false)
        @Expect(exists(Path(executionMarker)), false)
        var hasDeclaredExtension = false
        var hasBlockedHook = false
        for (component in record.descriptor.components) {
            if (component.kind == PluginComponentKind.Extension &&
                component.relativePath == "extensions/index.js") { hasDeclaredExtension = true }
            if (component.kind == PluginComponentKind.Hook &&
                component.status == PluginComponentStatus.Blocked) { hasBlockedHook = true }
        }
        @Expect(hasDeclaredExtension, true)
        @Expect(hasBlockedHook, true)
        let lock = String.fromUtf8(File.readFrom(Path(settings + "/plugins/lock.jsonl")))
        @Expect(lock.contains("local-plugin"), true)
        @Expect(lock.contains("1.0.0"), true)
        @Expect(lock.contains("content_digest"), true)

        File.writeTo(root + "/skills/demo/references/context.md", "Reference v2".toArray())
        @Expect(String.fromUtf8(File.readFrom(Path(record.descriptor.root + "/skills/demo/references/context.md"))), "Reference v1")
        File.writeTo(root + "/package.json", "{\"name\":\"local-plugin\",\"version\":\"2.0.0\",\"pi\":{\"skills\":[\"skills\"]}}".toArray())
        @Expect(runtime.list()[0].descriptor.version, "1.0.0")
        let reloaded = ProductPluginRuntime(settings, root)
        @Expect(reloaded.list().size, 1)
        @Expect(reloaded.list()[0].descriptor.id, "local-plugin")
        @Expect(reloaded.list()[0].descriptor.version, "1.0.0")
    }

    @TestCase
    func enabledPluginSkillsJoinExistingSkillRuntime(): Unit {
        let root = pluginContractTemp("plugin-skill")
        let settings = pluginContractTemp("plugin-skill-settings")
        Directory.create(root + "/skills/demo", recursive: true)
        Directory.create(root + "/skills/demo/references", recursive: true)
        Directory.create(root + "/skills/private", recursive: true)
        Directory.create(root + "/skills/team/reviewer", recursive: true)
        File.writeTo(root + "/package.json",
            "{\"name\":\"plugin-skill\",\"version\":\"1.0.0\",\"pi\":{\"skills\":[\"skills/d*\",\"skills/?emo\",\"skills/team/**\",\"!skills/private\"]}}".toArray())
        File.writeTo(root + "/skills/demo/SKILL.md",
            "---\nname: Demo skill\ndescription: Imported demo skill\ntriggers: demo\n---\nUse the demo skill. Read [guide](references/guide.md).\n".toArray())
        File.writeTo(root + "/skills/demo/references/guide.md", "Reference content from the imported package.".toArray())
        File.writeTo(root + "/skills/private/SKILL.md",
            "---\nname: Private skill\ndescription: Must stay excluded\n---\nPrivate instructions.\n".toArray())
        File.writeTo(root + "/skills/team/reviewer/SKILL.md",
            "---\nname: Reviewer skill\ndescription: Nested imported skill\n---\nReview carefully.\n".toArray())
        let runtime = ProductPluginRuntime(settings, root)
        let imported = match (runtime.importLocal(root)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        let disabledSkills = ProductSkillRuntime(settings, root, pluginRuntime: Some(runtime))
        @Expect(disabledSkills.metadata().isEmpty(), true)
        match (runtime.setEnabled(imported.descriptor.id, true)) {
            case PluginImportResult.Ok(_) => ()
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        let selectedRoots = runtime.enabledSkillRoots()
        var includesDemoRoot = false
        var includesReviewerRoot = false
        for (selectedRoot in selectedRoots) {
            if (selectedRoot.endsWith("/skills/demo")) { includesDemoRoot = true }
            if (selectedRoot.endsWith("/skills/team/reviewer")) { includesReviewerRoot = true }
        }
        @Expect(selectedRoots.size, 2)
        @Expect(includesDemoRoot, true)
        @Expect(includesReviewerRoot, true)
        let enabledSkills = ProductSkillRuntime(settings, root, pluginRuntime: Some(runtime))
        @Expect(enabledSkills.metadata().size, 2)
        var includesDemoSkill = false
        var includesReviewerSkill = false
        for (skill in enabledSkills.metadata()) {
            if (skill.id == "demo") { includesDemoSkill = true }
            if (skill.id == "reviewer") { includesReviewerSkill = true }
        }
        @Expect(includesDemoSkill, true)
        @Expect(includesReviewerSkill, true)
        let skillSnapshot = enabledSkills.resolve("please use demo", SkillStackSnapshot([], []))
        @Expect(skillSnapshot.active.size, 1)
        let referenceContent = match (enabledSkills.readReference(skillSnapshot, "demo", "guide.md")) {
            case Result.Ok(value) => value.content
            case Result.Err(error) => "error:" + error.code
        }
        @Expect(referenceContent, "Reference content from the imported package.")
    }
    @TestCase
    func standaloneSkillImportsIntoExistingSkillRuntime(): Unit {
        let root = pluginContractTemp("standalone-skill")
        let settings = pluginContractTemp("standalone-skill-settings")
        Directory.create(root + "/references", recursive: true)
        File.writeTo(root + "/SKILL.md",
            "---\nname: Standalone skill\ndescription: Imported standalone Skill\ntriggers: standalone\n---\nUse the standalone skill. Read [guide](references/guide.md).\n".toArray())
        File.writeTo(root + "/references/guide.md", "Standalone reference content.".toArray())

        let runtime = ProductPluginRuntime(settings, root)
        let imported = match (runtime.importLocal(root)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        @Expect(imported.descriptor.compatibilityProfile, "pi-skill-file-v1")
        @Expect(imported.descriptor.components.size, 1)
        @Expect(imported.descriptor.components[0].relativePath, "SKILL.md")
        @Expect(exists(Path(imported.descriptor.root + "/references/guide.md")), true)
        let disabledSkills = ProductSkillRuntime(settings, root, pluginRuntime: Some(runtime))
        @Expect(disabledSkills.metadata().isEmpty(), true)
        match (runtime.setEnabled(imported.descriptor.id, true)) {
            case PluginImportResult.Ok(_) => ()
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        let enabledRoots = runtime.enabledSkillRoots()
        @Expect(enabledRoots.size, 1)
        let skills = ProductSkillRuntime(settings, root, pluginRuntime: Some(runtime))
        let metadata = skills.metadata()
        @Expect(metadata.size, 1)
        let snapshot = skills.resolve("please use standalone", SkillStackSnapshot([], []))
        @Expect(snapshot.active.size, 1)
        let reference = match (skills.readReference(snapshot, metadata[0].id, "guide.md")) {
            case Result.Ok(value) => value.content
            case Result.Err(error) => "error:" + error.code
        }
        @Expect(reference, "Standalone reference content.")
    }
    @TestCase
    func localImporterRejectsArchiveFilesBeforeUnpacking(): Unit {
        let archivePath = pluginContractTemp("unsupported-archive") + ".zip"
        File.writeTo(archivePath, "archive traversal candidate: ../outside".toArray())
        let runtime = ProductPluginRuntime(pluginContractTemp("unsupported-archive-settings"), pluginContractTemp("workspace"))
        let result = runtime.importLocal(archivePath)
        @Expect(match (result) {
            case PluginImportResult.Err(error) => error.code == "plugin.root_invalid"
            case PluginImportResult.Ok(_) => false
        })
    }
    @TestCase
    func enabledPiPromptTemplatesRenderAsUntrustedUserInput(): Unit {
        let root = pluginContractTemp("plugin-prompt")
        let settings = pluginContractTemp("plugin-prompt-settings")
        Directory.create(root + "/prompts/deep", recursive: true)
        Directory.create(root + "/themes", recursive: true)
        Directory.create(root + "/prompts/private", recursive: true)
        File.writeTo(root + "/package.json",
            "{\"name\":\"plugin-prompt\",\"version\":\"1.0.0\",\"pi\":{\"prompts\":[\"prompts/**/*.md\",\"!prompts/private/**\"]}}".toArray())
        File.writeTo(root + "/prompts/deep/review.md",
            "---\ndescription: Review\nargument-hint: <task>\n---\nReview $ARGUMENTS only.\n".toArray())
        File.writeTo(root + "/prompts/private/hidden.md", "Hidden prompt.\n".toArray())
        let runtime = ProductPluginRuntime(settings, root)
        let imported = match (runtime.importLocal(root)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        @Expect(runtime.promptTemplateNames().isEmpty(), true)
        match (runtime.setEnabled(imported.descriptor.id, true)) {
            case PluginImportResult.Ok(_) => ()
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        let identity = imported.descriptor.namespace + "/prompts/deep/review.md"
        let hiddenIdentity = imported.descriptor.namespace + "/prompts/private/hidden.md"
        @Expect(runtime.promptTemplateNames(), [identity])
        var hasSupportedPrompt = false
        var hasBlockedTheme = false
        for (component in imported.descriptor.components) {
            if (component.kind == PluginComponentKind.Prompt &&
                component.status == PluginComponentStatus.Supported) { hasSupportedPrompt = true }
            if (component.kind == PluginComponentKind.Theme &&
                component.status == PluginComponentStatus.Blocked) { hasBlockedTheme = true }
        }
        @Expect(hasSupportedPrompt, true)
        @Expect(hasBlockedTheme, true)
        var reportsBlockedTheme = false
        for (error in runtime.diagnostics()) {
            if (error.code == "plugin.component_blocked" && error.message.contains("themes")) {
                reportsBlockedTheme = true
            }
        }
        @Expect(reportsBlockedTheme, true)
        @Expect(match (runtime.renderPromptTemplate(hiddenIdentity, [])) {
            case PluginImportResult.Err(error) => error.code == "plugin.prompt_not_found"
            case PluginImportResult.Ok(_) => false
        })
        let rendered = match (runtime.renderPromptTemplate(identity, ["feature", "task"])) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        @Expect(rendered, "Review feature task only.\n")
        let marker = pluginContractTemp("prompt-shell-marker")
        let shellArgument = "$(touch " + marker + ")"
        let shellRendered = match (runtime.renderPromptTemplate(identity, [shellArgument])) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        @Expect(shellRendered, "Review " + shellArgument + " only.\n")
        @Expect(exists(Path(marker)), false)
        let traversal = runtime.renderPromptTemplate(
            imported.descriptor.namespace + "/prompts/../package.json", [])
        @Expect(match (traversal) {
            case PluginImportResult.Err(error) => error.code == "plugin.prompt_path_invalid"
            case PluginImportResult.Ok(_) => false
        })
        match (runtime.setEnabled(imported.descriptor.id, false)) {
            case PluginImportResult.Ok(_) => ()
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        @Expect(runtime.promptTemplateNames().isEmpty(), true)
    }

    @TestCase
    func enabledPortableCodexMcpUsesDeclaredManifestComponent(): Unit {
        let root = pluginContractTemp("plugin-mcp")
        let settings = pluginContractTemp("plugin-mcp-settings")
        Directory.create(root)
        File.writeTo(root + "/plugin.json",
            "{\"$schema\":\"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json\",\"name\":\"plugin-mcp\",\"version\":\"1.0.0\",\"description\":\"MCP fixture\"}".toArray())
        File.writeTo(root + "/mcp.json",
            "{\"$schema\":\"https://agent-plugins.org/schemas/1.0.0/mcp.schema.json\",\"mcpServers\":{\"fixture\":{\"type\":\"stdio\",\"command\":\"node\",\"args\":[\"server.js\"]},\"http-fixture\":{\"type\":\"streamable-http\",\"url\":\"https://mcp.example.test\",\"origin\":\"https://client.example.test\"}}}".toArray())
        let runtime = ProductPluginRuntime(settings, root)
        let imported = match (runtime.importLocal(root)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        match (runtime.setEnabled(imported.descriptor.id, true)) {
            case PluginImportResult.Ok(_) => ()
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        let configs = match (loadProductMcpConfig(settings, pluginRuntime: Some(runtime))) {
            case Result.Ok(value) => value
            case Result.Err(error) => throw IllegalStateException(error.code)
        }
        @Expect(configs.size, 2)
        @Expect(configs[0].id, "plugin-" + modelPolicySha256Text("codex:plugin-mcp") + "-fixture")
        @Expect(configs[0].transport, ProductMcpTransportKind.Stdio)
        @Expect(configs[0].packageRoot, imported.descriptor.root)
        match (configs[0].stdio) {
            case Some(value) =>
                @Expect(value.command, "node")
                @Expect(value.arguments, ["server.js"])
                @Expect(value.cwd, imported.descriptor.root)
            case None => throw IllegalStateException("adapted MCP stdio transport is missing")
        }
        @Expect(configs[1].transport, ProductMcpTransportKind.StreamableHttp)
        @Expect(configs[1].networkPolicy.mode, NetworkPolicyMode.Mediated)
        @Expect(configs[1].networkPolicy.egress.size, 1)
        @Expect(configs[1].networkPolicy.egress[0].host, "mcp.example.test")
        @Expect(configs[1].networkPolicy.egress[0].port, 443u16)
        match (configs[1].http) {
            case Some(value) =>
                @Expect(value.url, "https://mcp.example.test")
                @Expect(value.bearerTokenEnvironment, "")
                @Expect(value.origin, "https://client.example.test")
                @Expect(value.headers.isEmpty(), true)
            case None => throw IllegalStateException("adapted MCP HTTP transport is missing")
        }
    }
    @TestCase
    func unavailablePluginMcpIsDisabledWithoutBlockingProductStartup(): Unit {
        let root = pluginContractTemp("plugin-mcp-startup-isolation")
        let settings = root + "/settings"
        let state = root + "/state"
        let workspace = root + "/workspace"
        let source = root + "/source"
        for (path in [settings, state, workspace, source]) {
            Directory.create(path, recursive: true)
        }
        File.writeTo(source + "/plugin.json",
            "{\"name\":\"broken-mcp-plugin\",\"version\":\"1.0.0\"}".toArray())
        File.writeTo(source + "/mcp.json",
            "{\"mcpServers\":{\"broken\":{\"type\":\"stdio\",\"command\":\"./missing-server\"}}}".toArray())
        let pluginRuntime = ProductPluginRuntime(settings, workspace)
        let imported = match (pluginRuntime.importLocal(source)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
        }
        match (pluginRuntime.setEnabled(imported.descriptor.id, true)) {
            case PluginImportResult.Ok(_) => ()
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
        }
        let product = match (openProduct(config: ProductConfig(
            settingsRoot: settings,
            stateRoot: state,
            workspaceRoot: workspace,
            fixture: true
        ))) {
            case Result.Ok(value) => value
            case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
        }
        try {
            var foundDisabled = false
            for (record in product.pluginSnapshots() where
                record.descriptor.namespace == imported.descriptor.namespace) {
                foundDisabled = !record.enabled
            }
            @Expect(foundDisabled, true)
        } finally {
            let _ = product.close()
            remove(root, recursive: true)
        }
    }

    @TestCase
    func startupFailsWhenBrokenPluginQuarantineCannotPersist(): Unit {
        let root = pluginContractTemp("plugin-startup-quarantine-failure")
        let settings = root + "/settings"
        let state = root + "/state"
        let workspace = root + "/workspace"
        let source = root + "/source"
        for (path in [settings, state, workspace, source]) {
            Directory.create(path, recursive: true)
        }
        File.writeTo(source + "/plugin.json",
            "{\"name\":\"broken-quarantine-plugin\",\"version\":\"1.0.0\"}".toArray())
        File.writeTo(source + "/mcp.json",
            "{\"mcpServers\":{\"broken\":{\"type\":\"stdio\",\"command\":\"./missing-server\"}}}".toArray())
        let pluginRuntime = ProductPluginRuntime(settings, workspace)
        let imported = match (pluginRuntime.importLocal(source)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        match (pluginRuntime.setEnabled(imported.descriptor.id, true)) {
            case PluginImportResult.Ok(_) => ()
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        let pluginsInfo = FileInfo(Path(settings + "/plugins"))
        let _ = pluginsInfo.setWritable(false)
        try {
            @Expect(match (openProduct(config: ProductConfig(
                settingsRoot: settings,
                stateRoot: state,
                workspaceRoot: workspace,
                fixture: true
            ))) {
                case Result.Err(error) => error.code == "plugin.startup_disable_failed"
                case Result.Ok(product) =>
                    let _ = product.close()
                    false
            }, true)
        } finally {
            let _ = pluginsInfo.setWritable(true)
            remove(root, recursive: true)
        }
    }

    @TestCase
    func portablePluginMcpRejectsPackageCredentialBindings(): Unit {
        let root = pluginContractTemp("plugin-mcp-credentials")
        let settings = pluginContractTemp("plugin-mcp-credentials-settings")
        Directory.create(root)
        File.writeTo(root + "/plugin.json",
            "{\"$schema\":\"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json\",\"name\":\"plugin-mcp-credentials\",\"version\":\"1.0.0\"}".toArray())
        File.writeTo(root + "/mcp.json",
            "{\"mcpServers\":{\"remote\":{\"type\":\"streamable-http\",\"url\":\"https://mcp.example.test\",\"bearer_token_env\":\"OPENAI_API_KEY\",\"headers\":{\"X-Api-Key\":\"MCP_API_KEY\"}}}}".toArray())
        let runtime = ProductPluginRuntime(settings, root)
        let imported = match (runtime.importLocal(root)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        match (runtime.setEnabled(imported.descriptor.id, true)) {
            case PluginImportResult.Ok(_) => ()
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        @Expect(match (loadProductMcpConfig(settings, pluginRuntime: Some(runtime))) {
            case Result.Err(error) => error.code == "mcp.plugin_config_invalid" &&
                error.message.contains("operator-owned mcp.yml")
            case Result.Ok(_) => false
        }, true)
    }
    @TestCase
    func portablePluginMcpRejectsPrivateHttpEndpoints(): Unit {
        let root = pluginContractTemp("plugin-mcp-private-http")
        let settings = pluginContractTemp("plugin-mcp-private-http-settings")
        Directory.create(root)
        File.writeTo(root + "/plugin.json",
            "{\"name\":\"plugin-mcp-private-http\",\"version\":\"1.0.0\"}".toArray())
        File.writeTo(root + "/mcp.json",
            "{\"mcpServers\":{\"private\":{\"type\":\"streamable-http\",\"url\":\"https://127.0.0.1/mcp\"}}}".toArray())
        let runtime = ProductPluginRuntime(settings, root)
        let imported = match (runtime.importLocal(root)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        match (runtime.setEnabled(imported.descriptor.id, true)) {
            case PluginImportResult.Ok(_) => ()
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        @Expect(match (loadProductMcpConfig(settings, pluginRuntime: Some(runtime))) {
            case Result.Err(error) => error.code == "mcp.plugin_config_invalid" &&
                error.message.contains("operator-owned mcp.yml")
            case Result.Ok(_) => false
        }, true)
    }
    @TestCase
    func legacyCodexInlineMcpServersReachProductConfiguration(): Unit {
        let root = pluginContractTemp("legacy-inline-mcp")
        let settings = pluginContractTemp("legacy-inline-mcp-settings")
        Directory.create(root + "/.codex-plugin", recursive: true)
        File.writeTo(root + "/.codex-plugin/plugin.json",
            "{\"name\":\"legacy-inline-mcp\",\"version\":\"1.0.0\",\"mcpServers\":{\"fixture\":{\"command\":\"local-mcp\",\"args\":[\"--fixture\"]}}}".toArray())
        let runtime = ProductPluginRuntime(settings, root)
        let imported = match (runtime.importLocal(root)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        match (runtime.setEnabled(imported.descriptor.namespace, true)) {
            case PluginImportResult.Ok(_) => ()
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        let configs = match (loadProductMcpConfig(settings, pluginRuntime: Some(runtime))) {
            case Result.Ok(value) => value
            case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
        }
        @Expect(configs.size, 1)
        @Expect(configs[0].id, "plugin-" + modelPolicySha256Text("codex:legacy-inline-mcp") + "-fixture")
        @Expect(configs[0].transport, ProductMcpTransportKind.Stdio)
        match (configs[0].stdio) {
            case Some(value) =>
                @Expect(value.command, "local-mcp")
                @Expect(value.arguments, ["--fixture"])
            case None => throw IllegalStateException("adapted legacy MCP stdio transport is missing")
        }
    }
    @TestCase
    func legacyCodexMcpCompanionFileReachesProductConfiguration(): Unit {
        let root = pluginContractTemp("legacy-companion-mcp")
        let settings = pluginContractTemp("legacy-companion-mcp-settings")
        Directory.create(root + "/.codex-plugin", recursive: true)
        File.writeTo(root + "/.codex-plugin/plugin.json",
            "{\"name\":\"legacy-companion-mcp\",\"version\":\"1.0.0\",\"mcpServers\":\"./mcp-servers.json\"}".toArray())
        File.writeTo(root + "/mcp-servers.json",
            "{\"mcpServers\":{\"companion\":{\"type\":\"stdio\",\"command\":\"local-mcp\",\"args\":[\"--companion\"]}}}".toArray())
        let runtime = ProductPluginRuntime(settings, root)
        let imported = match (runtime.importLocal(root)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        match (runtime.setEnabled(imported.descriptor.namespace, true)) {
            case PluginImportResult.Ok(_) => ()
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        let configs = match (loadProductMcpConfig(settings, pluginRuntime: Some(runtime))) {
            case Result.Ok(value) => value
            case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
        }
        @Expect(configs.size, 1)
        @Expect(configs[0].id, "plugin-" + modelPolicySha256Text(imported.descriptor.namespace) + "-companion")
        match (configs[0].stdio) {
            case Some(value) =>
                @Expect(value.command, "local-mcp")
                @Expect(value.arguments, ["--companion"])
            case None => throw IllegalStateException("adapted legacy companion MCP transport is missing")
        }
    }
    @TestCase
    func importedPortableCodexSkillsUseExistingSkillRuntime(): Unit {
        let root = pluginContractTemp("codex-skill")
        let settings = pluginContractTemp("codex-skill-settings")
        Directory.create(root + "/skills/research/references", recursive: true)
        File.writeTo(root + "/plugin.json",
            "{\"$schema\":\"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json\",\"name\":\"codex-skill\",\"version\":\"1.0.0\"}".toArray())
        File.writeTo(root + "/skills/research/SKILL.md",
            "---\nname: Codex research\ndescription: Imported Codex Skill\ntriggers: codex research\n---\nUse this Codex Skill. Read [guide](references/guide.md).\n".toArray())
        File.writeTo(root + "/skills/research/references/guide.md",
            "Reference preserved in the Codex package snapshot.".toArray())
        let runtime = ProductPluginRuntime(settings, root)
        let imported = match (runtime.importLocal(root)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        @Expect(imported.descriptor.ecosystem, PluginEcosystem.Codex)
        match (runtime.setEnabled(imported.descriptor.namespace, true)) {
            case PluginImportResult.Ok(_) => ()
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        let skills = ProductSkillRuntime(settings, root, pluginRuntime: Some(runtime))
        let metadata = skills.metadata()
        @Expect(metadata.size, 1)
        let snapshot = skills.resolve("please use codex research", SkillStackSnapshot([], []))
        @Expect(snapshot.active.size, 1)
        let reference = match (skills.readReference(snapshot, metadata[0].id, "guide.md")) {
            case Result.Ok(value) => value.content
            case Result.Err(error) => "error:" + error.code
        }
        @Expect(reference, "Reference preserved in the Codex package snapshot.")
    }
    @TestCase
    func codexCommandHooksWithoutCapabilityGrantsRemainInactive(): Unit {
        let root = pluginContractTemp("codex-hook-runtime")
        let settings = root + "/settings"
        let state = root + "/state"
        let workspace = root + "/workspace"
        let source = root + "/plugin"
        Directory.create(source, recursive: true)
        Directory.create(settings, recursive: true)
        Directory.create(state, recursive: true)
        Directory.create(workspace, recursive: true)

        let command =
            "IFS= read -r event; case \"$event\" in *'\"event_name\":\"PreToolUse\"'*) ;; *) exit 8 ;; esac; case \"$event\" in " +
            "*hook_deny*) printf '%s\\n' '{\"decision\":\"deny\",\"reason\":\"blocked by hook\"}' ;; " +
            "*) printf '%s\\n' '{\"decision\":\"modify\",\"arguments\":{\"text\":\"modified\"}}' ;; esac"
        let preCommand = objectValue([
            ValueField("type", textValue("command")),
            ValueField("command", textValue(command)),
            ValueField("timeout", integerValue(5))
        ])
        let preGroup = objectValue([
            ValueField("matcher", textValue("*")),
            ValueField("hooks", listValue([preCommand]))
        ])
        let postGroup = objectValue([
            ValueField("matcher", textValue("*")),
            ValueField("hooks", listValue([objectValue([
                ValueField("type", textValue("command")),
                ValueField("command", textValue("IFS= read -r event; case \"$event\" in *'\"event_name\":\"PostToolUse\"'*) exit 9 ;; *) exit 8 ;; esac")),
                ValueField("timeout", integerValue(5))
            ])]))
        ])
        let manifest = objectValue([
            ValueField("$schema", textValue("https://agent-plugins.org/schemas/1.0.0/plugin.schema.json")),
            ValueField("name", textValue("codex-hook-runtime")),
            ValueField("version", textValue("1.0.0")),
            ValueField("hooks", objectValue([
                ValueField("PreToolUse", listValue([preGroup])),
                ValueField("PostToolUse", listValue([postGroup]))
            ]))
        ])
        File.writeTo(source + "/plugin.json", stringifyUnifiedJson(manifest).toArray())

        let product = match (openProduct(config: ProductConfig(
            settingsRoot: settings,
            stateRoot: state,
            workspaceRoot: workspace,
            fixture: true
        ))) {
            case Result.Ok(value) => value
            case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
        }
        try {
            let imported = match (product.importLocalPlugin(source)) {
                case PluginImportResult.Ok(value) => value
                case PluginImportResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            @Expect(imported.descriptor.root.startsWith(settings + "/plugins/packages/"), true)
            match (product.setPluginEnabled(imported.descriptor.id, true)) {
                case PluginImportResult.Ok(_) => ()
                case PluginImportResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }

            let schema = objectSchema([schemaProperty("text", "string")], ["text"])
            let echoRecorder = CodexHookToolRecorder()
            match (product.registerTool(ToolDescriptor(
                ModelToolDefinition("hook_echo", "Echo hook arguments", schema),
                Capability(CapabilityKind.WorkspaceRead)
            ), echoRecorder)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            let fixture = match (product.fixtureProbe) {
                case Some(value) => value
                case None => throw IllegalStateException("fixture model port is missing")
            }
            fixture.enqueueToolCallReply(
                "hook-echo-call", "hook_echo",
                objectValue([ValueField("text", textValue("original"))])
            )
            let echoSession = SessionId("codex-hook-echo")
            let echoRun = product.client.start(
                product.request("call hook_echo", sessionId: Some(echoSession)),
                { _ => () }
            )
            @Expect(match (echoRun) {
                case Result.Ok(AgentRunOutcome.Completed(_)) => true
                case _ => false
            }, true)
            @Expect(echoRecorder.invocations.size, 1)
            if (!echoRecorder.invocations.isEmpty()) {
                @Expect(
                    echoRecorder.invocations[0],
                    "hook-echo-call|hook_echo|" + canonicalAgentValue(objectValue([
                        ValueField("text", textValue("original"))
                    ]))
                )
            }

            var originalCallPreserved = false
            var committedResultPreserved = false
            let echoItems = match (product.threadItems(echoSession)) {
                case Result.Ok(value) => value
                case Result.Err(error) => throw IllegalStateException(error.code)
            }
            for (item in echoItems) {
                match (item.content) {
                    case ThreadItemContent.ToolCall(callId, name, arguments) =>
                        if (callId.value == "hook-echo-call" && name == "hook_echo" &&
                            canonicalAgentValue(arguments) == canonicalAgentValue(objectValue([
                                ValueField("text", textValue("original"))
                            ]))) {
                            originalCallPreserved = true
                        }
                    case ThreadItemContent.ToolResult(callId, _, receiptId, result, isError) =>
                        if (callId.value == "hook-echo-call" && receiptId != "" && !isError &&
                            canonicalAgentValue(result) == canonicalAgentValue(textValue("executed"))) {
                            committedResultPreserved = true
                        }
                    case _ => ()
                }
            }
            @Expect(originalCallPreserved, true)
            @Expect(committedResultPreserved, true)
            @Expect(product.codexHookDiagnostics().isEmpty(), true)

        } finally {
            let _ = product.close()
            remove(root, recursive: true)
        }
    }

    @TestCase
    func piEventHooksPreserveOrderRevalidateAndIsolateThreadState(): Unit {
        let root = pluginContractTemp("pi-event-state")
        let settings = root + "/home"
        let state = root + "/state"
        let workspace = root + "/workspace"
        let source = workspace + "/plugin"
        Directory.create(settings, recursive: true)
        Directory.create(state, recursive: true)
        Directory.create(source + "/extensions", recursive: true)
        File.writeTo(source + "/package.json",
            "{\"name\":\"pi-event-state\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"],\"axyndra\":{\"capabilities\":[\"workspace.read\",\"workspace.write\"]}}}".toArray())
        File.writeTo(source + "/extensions/index.js", (
            "let calls = 0;\n" +
            "export default function (pi) {\n" +
            "  pi.on('tool_call', event => {\n" +
            "    calls += 1;\n" +
            "    if (event.input.text === 'deny') return { block: true, reason: 'blocked by Pi hook' };\n" +
            "    if (event.input.text === 'invalid') { event.input.text = 17; return; }\n" +
            "    event.input.text += ':' + calls;\n" +
            "  });\n" +
            "  pi.on('tool_call', event => {\n" +
            "    if (typeof event.input.text === 'string') event.input.text += ':second';\n" +
            "  });\n" +
            "  pi.on('tool_result', () => ({ content: [{ type: 'text', text: 'replacement' }] }));\n" +
            "}\n"
        ).toArray())
        let product = match (openProduct(config: ProductConfig(
            settingsRoot: settings, stateRoot: state, workspaceRoot: workspace, fixture: true
        ))) {
            case Result.Ok(value) => value
            case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
        }
        try {
            let imported = match (product.importLocalPlugin(source)) {
                case PluginImportResult.Ok(value) => value
                case PluginImportResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            @Expect(imported.descriptor.root.startsWith(settings + "/plugins/packages/"), true)
            match (product.setPluginEnabled(imported.descriptor.id, true)) {
                case PluginImportResult.Ok(_) => ()
                case PluginImportResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            let recorder = CodexHookToolRecorder()
            let schema = objectSchema([schemaProperty("text", "string")], ["text"])
            match (product.registerTool(ToolDescriptor(
                ModelToolDefinition("pi_hook_echo", "Echo Pi hook arguments", schema),
                Capability(CapabilityKind.WorkspaceRead)
            ), recorder)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            let fixture = match (product.fixtureProbe) {
                case Some(value) => value
                case None => throw IllegalStateException("fixture model port is missing")
            }
            let threadA = SessionId("pi-hook-thread-a")
            let threadB = SessionId("pi-hook-thread-b")

            fixture.enqueueToolCallReply("pi-a-first", "pi_hook_echo",
                objectValue([ValueField("text", textValue("alpha"))]))
            let first = product.client.start(
                product.request("call pi_hook_echo", sessionId: Some(threadA)), { _ => () }
            )
            @Expect(match (first) {
                case Result.Ok(AgentRunOutcome.Completed(_)) => true
                case _ => false
            }, true)

            fixture.enqueueToolCallReply("pi-a-second", "pi_hook_echo",
                objectValue([ValueField("text", textValue("beta"))]))
            let second = product.client.start(
                product.request("call pi_hook_echo again", sessionId: Some(threadA)), { _ => () }
            )
            @Expect(match (second) {
                case Result.Ok(AgentRunOutcome.Completed(_)) => true
                case _ => false
            }, true)

            fixture.enqueueToolCallReply("pi-b-first", "pi_hook_echo",
                objectValue([ValueField("text", textValue("gamma"))]))
            let third = product.client.start(
                product.request("call pi_hook_echo", sessionId: Some(threadB)), { _ => () }
            )
            @Expect(match (third) {
                case Result.Ok(AgentRunOutcome.Completed(_)) => true
                case _ => false
            }, true)

            let expectedAlpha = canonicalAgentValue(objectValue([
                ValueField("text", textValue("alpha:1:second"))
            ]))
            let expectedBeta = canonicalAgentValue(objectValue([
                ValueField("text", textValue("beta:2:second"))
            ]))
            let expectedGamma = canonicalAgentValue(objectValue([
                ValueField("text", textValue("gamma:1:second"))
            ]))
            @Expect(recorder.invocations.size, 3)
            if (recorder.invocations.size == 3) {
                @Expect(recorder.invocations[0], "pi-a-first|pi_hook_echo|" + expectedAlpha)
                @Expect(recorder.invocations[1], "pi-a-second|pi_hook_echo|" + expectedBeta)
                @Expect(recorder.invocations[2], "pi-b-first|pi_hook_echo|" + expectedGamma)
            }

            fixture.enqueueToolCallReply("pi-a-invalid", "pi_hook_echo",
                objectValue([ValueField("text", textValue("invalid"))]))
            let invalid = product.client.start(
                product.request("call pi_hook_echo invalid", sessionId: Some(threadA)), { _ => () }
            )
            @Expect(match (invalid) {
                case Result.Ok(AgentRunOutcome.Completed(_)) => true
                case _ => false
            }, true)

            fixture.enqueueToolCallReply("pi-a-deny", "pi_hook_echo",
                objectValue([ValueField("text", textValue("deny"))]))
            let denied = product.client.start(
                product.request("call pi_hook_echo denied", sessionId: Some(threadA)), { _ => () }
            )
            @Expect(match (denied) {
                case Result.Ok(AgentRunOutcome.Completed(_)) => true
                case _ => false
            }, true)
            @Expect(recorder.invocations.size, 3)

            let threadItems = match (product.threadItems(threadA)) {
                case Result.Ok(value) => value
                case Result.Err(error) => throw IllegalStateException(error.code)
            }
            var originalCallPreserved = false
            var canonicalResultPreserved = false
            var invalidModificationRejected = false
            var blockedCallCommitted = false
            for (item in threadItems) {
                match (item.content) {
                    case ThreadItemContent.ToolCall(callId, name, arguments) =>
                        if (callId.value == "pi-a-first" && name == "pi_hook_echo" &&
                            canonicalAgentValue(arguments) == canonicalAgentValue(objectValue([
                                ValueField("text", textValue("alpha"))
                            ]))) {
                            originalCallPreserved = true
                        }
                    case ThreadItemContent.ToolResult(callId, _, receiptId, result, isError) =>
                        if (callId.value == "pi-a-first" && receiptId != "" && !isError &&
                            canonicalAgentValue(result) == canonicalAgentValue(textValue("executed"))) {
                            canonicalResultPreserved = true
                        }
                        if (callId.value == "pi-a-invalid" && isError &&
                            canonicalAgentValue(result).contains("tool.invalid_arguments")) {
                            invalidModificationRejected = true
                        }
                        if (callId.value == "pi-a-deny" && isError &&
                            canonicalAgentValue(result).contains("tool.hook_denied")) {
                            blockedCallCommitted = true
                        }
                    case _ => ()
                }
            }
            @Expect(originalCallPreserved, true)
            @Expect(canonicalResultPreserved, true)
            @Expect(invalidModificationRejected, true)
            @Expect(blockedCallCommitted, true)
            var observerFailureReported = false
            for (diagnostic in product.codexHookDiagnostics()) {
                if (diagnostic.contains("PostToolUse") &&
                    diagnostic.contains("extension.pi_hook_observer_invalid")) {
                    observerFailureReported = true
                }
            }
            @Expect(observerFailureReported, true)
        } finally {
            let _ = product.close()
            remove(root, recursive: true)
        }
    }


    @TestCase
    func packageInspectionReportsOnlyUninstalledRequiredDependencies(): Unit {
        let root = pluginContractTemp("plugin-dependencies")
        Directory.create(root, recursive: true)
        File.writeTo(root + "/package.json",
            "{\"name\":\"dependency-plugin\",\"version\":\"1.0.0\",\"pi\":{\"skills\":[\"skills\"]},\"dependencies\":{\"required-dep\":\"^1.0.0\"},\"optionalDependencies\":{\"optional-dep\":\"^1.0.0\"},\"devDependencies\":{\"dev-dep\":\"^1.0.0\"}}".toArray())
        let runtime = ProductPluginRuntime(root + "/settings", root)
        let beforeInstall = match (runtime.inspect(root)) {
            case PluginPackageResult.Ok(value) => value
            case PluginPackageResult.Err(error) => throw IllegalStateException(error.code)
        }
        @Expect(beforeInstall.missingDependencies, ["required-dep"])
        @Expect(beforeInstall.dependencies.size, 3)

        Directory.create(root + "/node_modules/required-dep", recursive: true)
        let afterInstall = match (runtime.inspect(root)) {
            case PluginPackageResult.Ok(value) => value
            case PluginPackageResult.Err(error) => throw IllegalStateException(error.code)
        }
        @Expect(afterInstall.missingDependencies.isEmpty(), true)
    }
    @TestCase
    func portableCodexManifestKeepsIdentityAndReadsCompatOverlay(): Unit {
        let root = pluginContractTemp("codex-precedence")
        Directory.create(root + "/.codex-plugin", recursive: true)
        File.writeTo(root + "/plugin.json",
            "{\"$schema\":\"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json\",\"name\":\"portable-id\",\"version\":\"2.0.0\"}".toArray())
        File.writeTo(root + "/.codex-plugin/plugin.json",
            "{\"name\":\"compat-id\",\"version\":\"1.0.0\",\"extensions\":{\"com.openai\":{\"skills\":[]}}}".toArray())
        let runtime = ProductPluginRuntime(root + "/settings", root)
        let descriptor = match (runtime.inspect(root)) {
            case PluginPackageResult.Ok(value) => value
            case PluginPackageResult.Err(error) => throw IllegalStateException(error.code)
        }
        @Expect(descriptor.id, "portable-id")
        @Expect(descriptor.version, "2.0.0")
        @Expect(descriptor.manifestPath, "plugin.json")
        @Expect(descriptor.overlayPath, ".codex-plugin/plugin.json")
    }
    @TestCase
    func piManifestFieldOverridesOnlyItsConventionalResourceType(): Unit {
        let root = pluginContractTemp("pi-precedence")
        Directory.create(root + "/skills", recursive: true)
        Directory.create(root + "/prompts", recursive: true)
        Directory.create(root + "/extensions", recursive: true)
        File.writeTo(root + "/package.json",
            "{\"name\":\"pi-defaults\",\"version\":\"1.0.0\",\"pi\":{\"skills\":[]}}".toArray())
        let runtime = ProductPluginRuntime(root + "/settings", root)
        let descriptor = match (runtime.inspect(root)) {
            case PluginPackageResult.Ok(value) => value
            case PluginPackageResult.Err(error) => throw IllegalStateException(error.code)
        }
        @Expect(descriptor.components.size, 2)
        @Expect(descriptor.components[0].kind, PluginComponentKind.Prompt)
        @Expect(descriptor.components[0].relativePath, "prompts")
        @Expect(descriptor.components[1].kind, PluginComponentKind.Extension)
        @Expect(descriptor.components[1].relativePath, "extensions")
    }
    @TestCase
    func conventionalPiResourcesConflictWithCodexPackageIdentity(): Unit {
        let root = pluginContractTemp("pi-codex-conflict")
        Directory.create(root + "/skills", recursive: true)
        File.writeTo(root + "/package.json",
            "{\"name\":\"pi-conventions\",\"version\":\"1.0.0\"}".toArray())
        File.writeTo(root + "/plugin.json",
            "{\"$schema\":\"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json\",\"name\":\"codex-portable\",\"version\":\"1.0.0\"}".toArray())
        let result = inspectPluginPackage(root)
        @Expect(match (result) {
            case PluginPackageResult.Err(error) => error.code == "plugin.manifest_conflict"
            case PluginPackageResult.Ok(_) => false
        })
    }

    @TestCase
    func unrelatedRootPluginJsonDoesNotHideLegacyCodexManifest(): Unit {
        let root = pluginContractTemp("codex-legacy-fallback")
        Directory.create(root + "/.codex-plugin", recursive: true)
        File.writeTo(root + "/plugin.json",
            "{\"$schema\":\"https://example.test/unrelated.schema.json\",\"name\":\"unrelated\",\"version\":\"9.0.0\"}".toArray())
        File.writeTo(root + "/.codex-plugin/plugin.json",
            "{\"name\":\"legacy-id\",\"version\":\"1.0.0\"}".toArray())
        let descriptor = match (inspectPluginPackage(root)) {
            case PluginPackageResult.Ok(value) => value
            case PluginPackageResult.Err(error) => throw IllegalStateException(error.code)
        }
        @Expect(descriptor.id, "legacy-id")
        @Expect(descriptor.manifestPath, ".codex-plugin/plugin.json")
        @Expect(descriptor.compatibilityProfile, "codex-compat-v1")
    }
    @TestCase
    func packageNamespacesAllowSameIdAcrossEcosystems(): Unit {
        let root = pluginContractTemp("plugin-namespaces")
        let settings = pluginContractTemp("plugin-namespaces-settings")
        let piRoot = root + "/pi"
        let codexRoot = root + "/codex"
        Directory.create(piRoot, recursive: true)
        Directory.create(codexRoot, recursive: true)
        Directory.create(settings)
        File.writeTo(piRoot + "/package.json",
            "{\"name\":\"same-name\",\"version\":\"1.0.0\",\"pi\":{\"skills\":[\"skills\"]}}".toArray())
        File.writeTo(codexRoot + "/plugin.json",
            "{\"$schema\":\"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json\",\"name\":\"same-name\",\"version\":\"1.0.0\",\"description\":\"Fixture\"}".toArray())
        let runtime = ProductPluginRuntime(settings, root)
        let piNamespace = match (runtime.importLocal(piRoot)) {
            case PluginImportResult.Ok(record) => record.descriptor.namespace
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        let codexNamespace = match (runtime.importLocal(codexRoot)) {
            case PluginImportResult.Ok(record) => record.descriptor.namespace
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        @Expect(piNamespace != codexNamespace, true)
        @Expect(runtime.list().size, 2)
        @Expect(match (runtime.get("same-name")) {
            case None => true
            case Some(_) => false
        }, true)
        let ambiguous = match (runtime.setEnabled("same-name", true)) {
            case PluginImportResult.Ok(_) => "ok"
            case PluginImportResult.Err(error) => error.code
        }
        @Expect(ambiguous, "plugin.ambiguous_id")
        match (runtime.setEnabled(piNamespace, true)) {
            case PluginImportResult.Ok(_) => ()
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        match (runtime.setEnabled(codexNamespace, true)) {
            case PluginImportResult.Ok(_) => ()
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        @Expect(runtime.updateLocal(piNamespace, piRoot).isOk(), true)

        let reloaded = ProductPluginRuntime(settings, root)
        @Expect(reloaded.list().size, 2)
        @Expect(match (reloaded.get(piNamespace)) {
            case Some(record) => record.enabled
            case None => false
        }, true)
        @Expect(match (reloaded.get(codexNamespace)) {
            case Some(record) => record.enabled
            case None => false
        }, true)
        @Expect(reloaded.rollback(piNamespace).isOk(), true)
        @Expect(reloaded.uninstall(piNamespace).isOk(), true)
        @Expect(reloaded.list().size, 1)
        @Expect(match (reloaded.get(codexNamespace)) {
            case Some(_) => true
            case None => false
        }, true)
    }

    @TestCase
    func piExtensionApiHostRejectsCodexExecution(): Unit {
        let root = pluginContractTemp("host-namespaces")
        let piRoot = root + "/pi"
        let codexRoot = root + "/codex"
        Directory.create(piRoot, recursive: true)
        Directory.create(codexRoot, recursive: true)
        let script =
            "import { Type } from 'typebox';\n" +
            "export default function (pi) {\n" +
            "  pi.registerTool({ name: 'probe', label: 'Probe', description: 'Probe tool',\n" +
            "    parameters: Type.Object({}),\n" +
            "    execute: async () => ({ content: [{ type: 'text', text: 'Pi probe' }], details: {} }) });\n" +
            "}\n"
        File.writeTo(piRoot + "/probe.js", script.toArray())
        let piDescriptor = PluginPackageDescriptor(
            "same-name", "1.0.0", PluginEcosystem.Pi, PluginManifestFamily.Pi, "fixture",
            root: piRoot,
            components: [PluginComponent(PluginComponentKind.Extension, "probe.js")],
            entrypoint: "probe.js"
        )
        let codexDescriptor = PluginPackageDescriptor(
            "same-name", "1.0.0", PluginEcosystem.Codex, PluginManifestFamily.Codex, "fixture",
            root: codexRoot,
            components: [PluginComponent(PluginComponentKind.Extension, "probe.js")],
            entrypoint: "probe.js"
        )
        let piRecord = ProductPluginRecord(
            piDescriptor, PluginSourceKind.Local, piRoot, "1.0.0", "", "", "", false, 0
        )
        let codexRecord = ProductPluginRecord(
            codexDescriptor, PluginSourceKind.Local, codexRoot, "1.0.0", "", "", "", false, 0
        )
        let host = ProductJavaScriptPluginHost()
        try {
            match (host.mount(piRecord)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            @Expect(match (host.mount(codexRecord)) {
                case Result.Err(error) => error.code == "plugin.ecosystem_unsupported"
                case Result.Ok(_) => false
            }, true)
            let cancellation = CancellationSource()
            let piResult = match (host.invoke(
                piDescriptor.namespace, "probe", "{}",
                identity: JavaScriptHostInvocationIdentity(
                    threadId: "thread-pi-host", runId: "run-pi-host", epoch: 1,
                    operationId: "operation-pi-host", callId: "call-pi-host"
                ),
                cancellation: cancellation.token,
                cwd: piRoot
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            cancellation.close()
            @Expect(!piResult.isError && stringifyUnifiedJson(piResult.value).contains("Pi probe"), true)
            @Expect(host.toolNames(piDescriptor.namespace), ["probe"])
            @Expect(host.toolNames(codexDescriptor.namespace).isEmpty(), true)
            let _ = host.unmount(piDescriptor.namespace)
            @Expect(host.toolNames(piDescriptor.namespace).isEmpty(), true)
            @Expect(host.toolNames(codexDescriptor.namespace).isEmpty(), true)
        } finally {
            let _ = host.unmount(piDescriptor.namespace)
            let _ = host.unmount(codexDescriptor.namespace)
            remove(root, recursive: true)
        }
    }

    @TestCase
    func piExtensionUiRequestFailsWithoutFrontendResponder(): Unit {
        let root = pluginContractTemp("pi-ui-no-frontend")
        Directory.create(root, recursive: true)
        let script =
            "import { Type } from 'typebox';\n" +
            "export default function (pi) {\n" +
            "  pi.registerTool({ name: 'ask', label: 'Ask', description: 'Frontend interaction',\n" +
            "    parameters: Type.Object({}),\n" +
            "    execute: async (_id, _params, _signal, _update, ctx) => {\n" +
            "      await ctx.ui.confirm('Continue?');\n" +
            "      return { content: [{ type: 'text', text: 'unexpected confirmation' }] };\n" +
            "    } });\n" +
            "}\n"
        File.writeTo(root + "/probe.js", script.toArray())
        let descriptor = PluginPackageDescriptor(
            "pi-ui-no-frontend", "1.0.0", PluginEcosystem.Pi,
            PluginManifestFamily.Pi, "fixture", root: root,
            components: [PluginComponent(PluginComponentKind.Extension, "probe.js")],
            entrypoint: "probe.js"
        )
        let record = ProductPluginRecord(
            descriptor, PluginSourceKind.Local, root, "1.0.0", "", "", "", false, 0
        )
        let host = ProductJavaScriptPluginHost()
        try {
            @Expect(host.mount(record).isOk(), true)
            let cancellation = CancellationSource()
            let result = match (host.invoke(
                descriptor.namespace, "ask", "{}",
                identity: JavaScriptHostInvocationIdentity(
                    threadId: "thread-pi-ui", runId: "run-pi-ui", epoch: 1,
                    operationId: "operation-pi-ui", callId: "call-pi-ui"
                ),
                cancellation: cancellation.token,
                cwd: root
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            cancellation.close()
            @Expect(result.isError, true)
            @Expect(stringifyUnifiedJson(result.value).contains("extension.pi_interaction_unsupported"), true)
            @Expect(stringifyUnifiedJson(result.value).contains("no frontend responder"), true)
            @Expect(stringifyUnifiedJson(result.value).contains("unexpected confirmation"), false)
        } finally {
            let _ = host.unmount(descriptor.namespace)
            remove(root, recursive: true)
        }
    }

    @TestCase
    func piExtensionUiInteractionsReachResponder(): Unit {
        let root = pluginContractTemp("pi-ui-responder")
        Directory.create(root, recursive: true)
        let markerPath = root + "/services.log"
        let script =
            "import { Type } from 'typebox';\n" +
            "export default function (pi) {\n" +
            "  pi.registerTool({ name: 'interact', label: 'Interact', description: 'Frontend interaction',\n" +
            "    parameters: Type.Object({}),\n" +
            "    execute: async (_id, _params, _signal, _update, ctx) => {\n" +
            "      ctx.ui.notify('Build started', 'warning');\n" +
            "      const choice = await ctx.ui.select('Target', ['A', 'B'], { timeout: 2500, signal: ctx.signal });\n" +
            "      const confirmed = await ctx.ui.confirm('Proceed?', 'Apply choice?', { timeout: 2500, signal: ctx.signal });\n" +
            "      return { content: [{ type: 'text', text: choice + ':' + confirmed }] };\n" +
            "    } });\n" +
            "}\n"
        File.writeTo(root + "/probe.js", script.toArray())
        let descriptor = PluginPackageDescriptor(
            "pi-ui-responder", "1.0.0", PluginEcosystem.Pi,
            PluginManifestFamily.Pi, "fixture", root: root,
            components: [PluginComponent(PluginComponentKind.Extension, "probe.js")],
            entrypoint: "probe.js"
        )
        let record = ProductPluginRecord(
            descriptor, PluginSourceKind.Local, root, "1.0.0", "", "", "", false, 0
        )
        let host = ProductJavaScriptPluginHost()
        try {
            @Expect(host.mount(record).isOk(), true)
            let cancellation = CancellationSource()
            let result = match (host.invoke(
                descriptor.namespace, "interact", "{}",
                identity: JavaScriptHostInvocationIdentity(
                    threadId: "thread-pi-ui", runId: "run-pi-ui", epoch: 1,
                    operationId: "operation-pi-ui", callId: "call-pi-ui"
                ),
                cancellation: cancellation.token,
                cwd: root,
                hasUI: true,
                observer: Some(PiUiRecordingObserver(markerPath))
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            cancellation.close()
            let services = String.fromUtf8(File.readFrom(Path(markerPath)))
            @Expect(!result.isError && stringifyUnifiedJson(result.value).contains("B:true"), true)
            @Expect(services.contains("ui.notify:pi-service-1") &&
                services.contains("ui.select:pi-service-2") &&
                services.contains("ui.confirm:pi-service-3"), true)
            @Expect(services.contains("\"type\":\"warning\"") &&
                services.contains("\"options\":[\"A\",\"B\"]") &&
                services.contains("\"message\":\"Apply choice?\""), true)
        } finally {
            let _ = host.unmount(descriptor.namespace)
            remove(root, recursive: true)
        }
    }

    @TestCase
    func piExtensionCommandsUseCorrelatedFrontendInteractions() : Unit {
        let root = pluginContractTemp("pi-command-ui")
        Directory.create(root, recursive: true)
        let script =
            "export default function (pi) {\n" +
            "  pi.registerCommand('choose', { description: 'Choose an option', handler: async (args, ctx) => {\n" +
            "    ctx.ui.notify('Build ' + args, 'warning');\n" +
            "    const choice = await ctx.ui.select('Target', ['A', 'B'], { timeout: 2500, signal: ctx.signal });\n" +
            "    await ctx.ui.confirm('Proceed?', 'Apply ' + choice + '?', { timeout: 2500, signal: ctx.signal });\n" +
            "  }});\n" +
            "}\n"
        File.writeTo(root + "/probe.js", script.toArray())
        let descriptor = PluginPackageDescriptor(
            "pi-command-ui", "1.0.0", PluginEcosystem.Pi,
            PluginManifestFamily.Pi, "fixture", root: root,
            components: [PluginComponent(PluginComponentKind.Extension, "probe.js")],
            entrypoint: "probe.js"
        )
        let record = ProductPluginRecord(
            descriptor, PluginSourceKind.Local, root, "1.0.0", "", "", "", false, 0
        )
        let host = ProductJavaScriptPluginHost()
        let askRuntime = AskRuntime()
        let sessionId = SessionId("session-pi-command")
        askRuntime.setInteractive(sessionId, true)
        let notices = ArrayList<String>()
        try {
            @Expect(host.mount(record).isOk(), true)
            let commands = host.commands()
            @Expect(commands.size, 1)
            @Expect(commands[0].name, "choose")
            @Expect(commands[0].description, "Choose an option")
            let cancellation = CancellationSource()
            let observer = ProductJavaScriptPluginCommandObserver(
                askRuntime, sessionId, "command-1", cancellation.token,
                {kind, message => notices.add(kind + ":" + message)}
            )
            let pending = spawn {
                host.invoke(
                    descriptor.namespace, "choose", "{\"command_args\":\"from terminal\"}",
                    identity: JavaScriptHostInvocationIdentity(
                        threadId: sessionId.value, runId: "", epoch: 0,
                        operationId: "", callId: "", kind: "command", commandId: "command-1"
                    ),
                    cancellation: cancellation.token, cwd: root, hasUI: true,
                    observer: Some(observer)
                )
            }
            let selectDeadline = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() + 5000
            var selection: ?ProductAskRequest = None
            while (DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() < selectDeadline) {
                selection = askRuntime.current(sessionId)
                if (selection.isSome() && selection.getOrThrow().interactionKind == "select") { break }
                sleep(Duration.millisecond * 5)
            }
            @Expect(selection.isSome(), true)
            let selectRequest = selection.getOrThrow()
            @Expect(selectRequest.runId, "")
            @Expect(selectRequest.operationId, "")
            @Expect(selectRequest.callId, "")
            @Expect(selectRequest.commandId, "command-1")
            @Expect(askRuntime.resolve(
                sessionId, selectRequest.requestId,
                ProductAskResolution.Answers([ProductAskAnswer(
                    "selection", selectedOptions: ["B"]
                )])
            ).isOk(), true)
            let confirmDeadline = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() + 5000
            var confirmation: ?ProductAskRequest = None
            while (DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() < confirmDeadline) {
                confirmation = askRuntime.current(sessionId)
                if (confirmation.isSome() && confirmation.getOrThrow().interactionKind == "confirm") { break }
                sleep(Duration.millisecond * 5)
            }
            @Expect(confirmation.isSome(), true)
            let confirmRequest = confirmation.getOrThrow()
            @Expect(confirmRequest.callId, "")
            @Expect(confirmRequest.commandId, "command-1")
            @Expect(askRuntime.resolve(
                sessionId, confirmRequest.requestId,
                ProductAskResolution.Answers([ProductAskAnswer(
                    "confirmation", selectedOptions: ["Yes"]
                )])
            ).isOk(), true)
            let completed = pending.get()
            @Expect(completed.isOk(), true)
            let invocation = match (completed) {
                case Result.Ok(value) => value
                case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            @Expect(!invocation.isError, true)
            @Expect(notices.size, 1)
            @Expect(notices[0], "warning:Build from terminal")
            cancellation.close()

            askRuntime.setInteractive(sessionId, false)
            let headlessCancellation = CancellationSource()
            let headless = host.invoke(
                descriptor.namespace, "choose", "{\"command_args\":\"headless\"}",
                identity: JavaScriptHostInvocationIdentity(
                    threadId: sessionId.value, runId: "", epoch: 0,
                    operationId: "", callId: "", kind: "command", commandId: "command-2"
                ),
                cancellation: headlessCancellation.token, cwd: root, hasUI: false,
                observer: Some(ProductJavaScriptPluginCommandObserver(
                    askRuntime, sessionId, "command-2", headlessCancellation.token,
                    {_, _ => ()}
                ))
            )
            @Expect(headless.isOk(), true)
            let headlessResult = match (headless) {
                case Result.Ok(value) => value
                case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            @Expect(headlessResult.isError, true)
            @Expect(stringifyUnifiedJson(headlessResult.value).contains(
                "extension.pi_interaction_unsupported"
            ), true)
            headlessCancellation.close()
        } finally {
            let _ = host.unmount(descriptor.namespace)
            remove(root, recursive: true)
        }
    }

    @TestCase
    func userScopedAxyndraSnapshotActivatesFromManagedStorage(): Unit {
        let root = pluginContractTemp("managed-axyndra-user-plugin")
        let settings = root + "/home"
        let state = root + "/state"
        let workspace = root + "/workspace"
        let source = root + "/source"
        for (path in [settings, state, workspace, source]) {
            Directory.create(path, recursive: true)
        }
        File.writeTo(source + "/axyndra.plugin.json", (
            "{\"id\":\"managed-user-plugin\",\"version\":\"1.0.0\"," +
            "\"entrypoint\":\"plugin.sh\",\"capabilities\":[\"workspace.read\",\"network.access:api.example.test:443\"],\"signature\":\"trusted\"}"
        ).toArray())
        File.writeTo(source + "/plugin.sh", "#!/bin/sh\nexit 0\n".toArray())
        let product = match (openProduct(config: ProductConfig(
            settingsRoot: settings,
            stateRoot: state,
            workspaceRoot: workspace,
            fixture: true,
            extensionSignatureVerifier: Some(AcceptingPluginSignatureVerifier())
        ))) {
            case Result.Ok(value) => value
            case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
        }
        try {
            let imported = match (product.importLocalPlugin(source)) {
                case PluginImportResult.Ok(value) => value
                case PluginImportResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            @Expect(imported.descriptor.root.startsWith(settings + "/plugins/packages/"), true)
            match (product.setPluginEnabled(imported.descriptor.id, true)) {
                case PluginImportResult.Ok(record) => @Expect(record.enabled, true)
                case PluginImportResult.Err(error) =>
                    throw IllegalStateException(error.code + ": " + error.message)
            }
            let toolName = "plugin." + imported.descriptor.namespace + ".invoke"
            var underGrantedVisible = false
            for (definition in product.toolsFor(CapabilitySet(values: [
                Capability(CapabilityKind.ExtensionInvoke)
            ])) where definition.name == toolName) {
                underGrantedVisible = true
            }
            @Expect(underGrantedVisible, false)
            var fullyGrantedVisible = false
            for (definition in product.toolsFor(CapabilitySet(values: [
                Capability(CapabilityKind.ExtensionInvoke),
                Capability(CapabilityKind.WorkspaceRead),
                Capability(
                    CapabilityKind.NetworkAccess,
                    resource: networkEgressResource(NetworkEgressRule("api.example.test", 443u16))
                )
            ])) where definition.name == toolName) {
                fullyGrantedVisible = true
            }
            @Expect(fullyGrantedVisible, true)
        } finally {
            let _ = product.close()
            remove(root, recursive: true)
        }
    }
    @TestCase
    func isolatedPluginDeactivationRollbackRestoresMountedGeneration(): Unit {
        let root = pluginContractTemp("isolated-plugin-deactivation-rollback")
        let workspace = root + "/workspace"
        let managed = root + "/packages"
        let packageRoot = managed + "/fixture/digest"
        for (path in [workspace, packageRoot]) {
            Directory.create(path, recursive: true)
        }
        let manifest = SignedExtensionPackageManifest(
            "rollback-plugin",
            "1.0.0",
            "1.x",
            "1.x",
            "plugin.sh",
            [],
            [],
            [],
            1u32,
            "restart-safe",
            "digest",
            "trusted"
        )
        let launch = match (validateIsolatedPluginPackage(
            manifest,
            ExtensionExecutionKind.ProcessPlugin,
            1u64,
            [],
            AcceptingPluginSignatureVerifier(),
            packageRoot: packageRoot
        )) {
            case SafeLifecycleResult.Ok(value) => value
            case SafeLifecycleResult.Err(message) => throw IllegalStateException(message)
        }
        let host = ProductIsolatedPluginHost(
            LocalProcessPort(LocalWorkspace(workspace)),
            workspace,
            managedPackageRoots: [managed]
        )
        try {
            @Expect(host.mountInitial(launch).isOk(), true)
            @Expect(host.deactivate(manifest.id).isOk(), true)
            @Expect(host.restore(
                manifest.id,
                launch.generation,
                manifest.contentDigest,
                packageRoot
            ).isOk(), true)
            @Expect(host.mountInitial(launch).isError(), true)
        } finally {
            remove(root, recursive: true)
        }
    }

    @TestCase
    func commandOnlyPiPluginActivationIsAdvertisedAndRevoked(): Unit {
        let root = pluginContractTemp("pi-command-activation")
        let settings = root + "/home"
        let state = root + "/state"
        let workspace = root + "/workspace"
        let source = workspace + "/plugin"
        Directory.create(settings, recursive: true)
        Directory.create(state, recursive: true)
        Directory.create(source + "/extensions", recursive: true)
        File.writeTo(source + "/package.json",
            "{\"name\":\"command-only\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}".toArray())
        File.writeTo(source + "/extensions/index.js", (
            "export default function (pi) {\n" +
            "  pi.registerCommand('inspect', { description: 'Inspect state', handler: async () => {} });\n" +
            "}\n"
        ).toArray())
        let product = match (openProduct(config: ProductConfig(
            settingsRoot: settings, stateRoot: state, workspaceRoot: workspace, fixture: true
        ))) {
            case Result.Ok(value) => value
            case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
        }
        try {
            let imported = match (product.importLocalPlugin(source, PluginInstallScope.Workspace)) {
                case PluginImportResult.Ok(value) => value
                case PluginImportResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            @Expect(imported.descriptor.root.startsWith(settings + "/plugins/packages/"), true)
            @Expect(imported.descriptor.root.startsWith(workspace + "/"), false)
            @Expect(exists(Path(workspace + "/.axyndra/plugins/lock.jsonl")), true)
            @Expect(exists(Path(workspace + "/.axyndra/plugins/packages")), false)
            @Expect(imported.enabled, false)
            let enabled = match (product.setPluginEnabled(
                imported.descriptor.id, true, PluginInstallScope.Workspace
            )) {
                case PluginImportResult.Ok(_) => true
                case PluginImportResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            @Expect(enabled, true)
            let commands = product.applicationSession().javascriptPluginCommands()
            @Expect(commands.size, 1)
            if (commands.size == 1) {
                @Expect(commands[0].routeName, "plugin." + imported.descriptor.namespace + ".inspect")
                @Expect(commands[0].description, "Inspect state")
            }
            let disabled = match (product.setPluginEnabled(
                imported.descriptor.id, false, PluginInstallScope.Workspace
            )) {
                case PluginImportResult.Ok(_) => true
                case PluginImportResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            @Expect(disabled, true)
            let revokedCommands = product.applicationSession().javascriptPluginCommands()
            @Expect(revokedCommands.size, 0)
            match (product.setPluginEnabled(
                imported.descriptor.id, true, PluginInstallScope.Workspace
            )) {
                case PluginImportResult.Ok(_) => ()
                case PluginImportResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            @Expect(product.applicationSession().javascriptPluginCommands().size, 1)
            let closeResult = product.close()
            @Expect(closeResult.isOk(), true)
            @Expect(product.applicationSession().javascriptPluginCommands().size, 0)
        } finally {
            let _ = product.close()
            remove(root, recursive: true)
        }
    }

    @TestCase
    func scopedImportRevokesPreviouslyEffectivePlugin(): Unit {
        let root = pluginContractTemp("scoped-import-reconciliation")
        let settings = root + "/home"
        let state = root + "/state"
        let workspace = root
        let userSource = root + "/user-plugin"
        let workspaceSource = root + "/workspace-plugin"
        for (path in [settings, state, userSource + "/extensions", workspaceSource + "/extensions"]) {
            Directory.create(path, recursive: true)
        }
        File.writeTo(userSource + "/package.json",
            "{\"name\":\"scoped-import\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}".toArray())
        File.writeTo(userSource + "/extensions/index.js", (
            "export default function (pi) {\n" +
            "  pi.registerCommand('user', { description: 'User command', handler: async () => {} });\n" +
            "}\n"
        ).toArray())
        File.writeTo(workspaceSource + "/package.json",
            "{\"name\":\"scoped-import\",\"version\":\"2.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}".toArray())
        File.writeTo(workspaceSource + "/extensions/index.js", (
            "export default function (pi) {\n" +
            "  pi.registerCommand('workspace', { description: 'Workspace command', handler: async () => {} });\n" +
            "}\n"
        ).toArray())

        let bootstrap = ProductPluginRuntime(settings, workspace)
        let user = match (bootstrap.importLocal(userSource, PluginInstallScope.User)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
        }
        match (bootstrap.setEnabled(user.descriptor.id, true, PluginInstallScope.User)) {
            case PluginImportResult.Ok(_) => ()
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
        }
        let product = match (openProduct(config: ProductConfig(
            settingsRoot: settings, stateRoot: state, workspaceRoot: workspace, fixture: true
        ))) {
            case Result.Ok(value) => value
            case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
        }
        try {
            let before = product.applicationSession().javascriptPluginCommands()
            @Expect(before.size, 1)
            if (before.size == 1) {
                @Expect(before[0].routeName, "plugin." + user.descriptor.namespace + ".user")
            }
            let imported = match (product.importLocalPlugin(workspaceSource, PluginInstallScope.Workspace)) {
                case PluginImportResult.Ok(value) => value
                case PluginImportResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            @Expect(imported.enabled, false)
            @Expect(product.applicationSession().javascriptPluginCommands().size, 0)
        } finally {
            let _ = product.close()
            remove(root, recursive: true)
        }
    }

    @TestCase
    func workspaceGrantWriteFailurePreservesPreviousLock(): Unit {
        let root = pluginContractTemp("workspace-plugin-transaction")
        let settings = root + "/home"
        let workspace = root + "/workspace"
        let firstSource = workspace + "/first"
        let secondSource = workspace + "/second"
        for (path in [settings, firstSource, secondSource]) {
            Directory.create(path, recursive: true)
        }
        File.writeTo(firstSource + "/package.json",
            "{\"name\":\"transaction-first\",\"version\":\"1.0.0\",\"pi\":{\"skills\":[\"skills\"]}}".toArray())
        File.writeTo(secondSource + "/package.json",
            "{\"name\":\"transaction-second\",\"version\":\"1.0.0\",\"pi\":{\"skills\":[\"skills\"]}}".toArray())
        let runtime = ProductPluginRuntime(settings, workspace)
        let first = match (runtime.importLocal(firstSource, PluginInstallScope.Workspace)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
        }
        let lockPath = workspace + "/.axyndra/plugins/lock.jsonl"
        let previousLock = String.fromUtf8(File.readFrom(Path(lockPath)))
        let grantDirectory = settings + "/plugins/workspace-grants"
        remove(Path(grantDirectory), recursive: true)
        File.writeTo(grantDirectory, "not-a-directory".toArray())

        @Expect(runtime.importLocal(secondSource, PluginInstallScope.Workspace).isOk(), false)
        @Expect(String.fromUtf8(File.readFrom(Path(lockPath))), previousLock)
        @Expect(runtime.list().size, 1)
        let reloaded = ProductPluginRuntime(settings, workspace)
        @Expect(reloaded.list().size, 1)
        if (reloaded.list().size == 1) {
            @Expect(reloaded.list()[0].descriptor.namespace, first.descriptor.namespace)
        }
        remove(root, recursive: true)
    }
    @TestCase
    func startupUnscopedEnableAndUninstallHonorEffectivePluginScope(): Unit {
        let root = pluginContractTemp("scoped-startup-activation")
        let settings = root + "/home"
        let state = root + "/state"
        let workspace = root
        let userSource = workspace + "/user-plugin"
        let workspaceSource = workspace + "/workspace-plugin"
        for (path in [settings, state, userSource + "/extensions",
            workspaceSource + "/extensions"]) {
            Directory.create(path, recursive: true)
        }
        File.writeTo(userSource + "/package.json",
            "{\"name\":\"scoped-startup\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}".toArray())
        File.writeTo(userSource + "/extensions/index.js", (
            "export default function (pi) {\n" +
            "  pi.registerCommand('user', { description: 'User command', handler: async () => {} });\n" +
            "}\n"
        ).toArray())
        File.writeTo(workspaceSource + "/package.json",
            "{\"name\":\"scoped-startup\",\"version\":\"2.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}".toArray())
        File.writeTo(workspaceSource + "/extensions/index.js", (
            "export default function (pi) {\n" +
            "  pi.registerCommand('workspace', { description: 'Workspace command', handler: async () => {} });\n" +
            "}\n"
        ).toArray())

        let bootstrap = ProductPluginRuntime(settings, workspace)
        let user = match (bootstrap.importLocal(userSource, PluginInstallScope.User)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
        }
        let scoped = match (bootstrap.importLocal(workspaceSource, PluginInstallScope.Workspace)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
        }
        match (bootstrap.setEnabled(user.descriptor.id, true, PluginInstallScope.User)) {
            case PluginImportResult.Ok(_) => ()
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
        }
        match (bootstrap.setEnabled(scoped.descriptor.id, true, PluginInstallScope.Workspace)) {
            case PluginImportResult.Ok(_) => ()
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
        }
        match (bootstrap.setEnabled(user.descriptor.id, false, PluginInstallScope.User)) {
            case PluginImportResult.Ok(_) => ()
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
        }

        let product = match (openProduct(config: ProductConfig(
            settingsRoot: settings, stateRoot: state, workspaceRoot: workspace, fixture: true
        ))) {
            case Result.Ok(value) => value
            case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
        }
        try {
            let namespace = scoped.descriptor.namespace
            let startupCommands = product.applicationSession().javascriptPluginCommands()
            @Expect(startupCommands.size, 0)
            match (product.setPluginEnabled(scoped.descriptor.id, true)) {
                case PluginImportResult.Ok(_) => ()
                case PluginImportResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            let enabledCommands = product.applicationSession().javascriptPluginCommands()
            @Expect(enabledCommands.size, 1)
            if (enabledCommands.size == 1) {
                @Expect(enabledCommands[0].routeName, "plugin." + namespace + ".workspace")
            }

            match (product.uninstallPlugin(scoped.descriptor.id)) {
                case PluginImportResult.Ok(_) => ()
                case PluginImportResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            let exposedCommands = product.applicationSession().javascriptPluginCommands()
            @Expect(exposedCommands.size, 1)
            if (exposedCommands.size == 1) {
                @Expect(exposedCommands[0].routeName, "plugin." + namespace + ".user")
            }
        } finally {
            let _ = product.close()
            remove(root, recursive: true)
        }
    }

    @TestCase
    func piExtensionApiHostDeniesDirectSystemAccess(): Unit {
        let cacheRoot = homeDirectory() + "/.cache/agent-tmp"
        if (!exists(Path(cacheRoot))) { Directory.create(cacheRoot, recursive: true) }
        let root = cacheRoot + "/axyndra-pi-isolation-" +
            DateTime.nowUTC().toUnixTimeStamp().toMilliseconds().toString()
        Directory.create(root, recursive: true)
        let port = 40000 + DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() % 20000
        let serverSource =
            "const fs=require('node:fs');const net=require('node:net');" +
            "const server=net.createServer(socket=>socket.end('reachable'));" +
            "server.once('error',()=>process.exit(2));" +
            "server.listen(" + port.toString() + ",'127.0.0.1',()=>" +
            "fs.writeFileSync('server-ready','ready'));"
        let server = process.startProcess(process.ProcessCommand(
            "node",
            arguments: ["-e", serverSource],
            workingDirectory: root,
            maxOutputBytes: 4096
        ))
        let script =
            "import { Type } from 'typebox';\n" +
            "export default function (pi) {\n" +
            "  pi.registerTool({ name: 'probe', label: 'Probe', description: 'Probe host isolation', parameters: Type.Object({}),\n" +
            "    execute: async () => {\n" +
            "      const denied = { fsReadDenied: false, fsWriteDenied: false, processDenied: false, networkDenied: false };\n" +
            "      try { const fs = await import('node:fs'); fs.readFileSync('/etc/passwd'); } catch (error) { denied.fsReadDenied = error.code === 'ERR_ACCESS_DENIED'; }\n" +
            "      try { const fs = await import('node:fs'); fs.writeFileSync(process.cwd() + '/direct-write-probe', 'unsafe'); } catch (error) { denied.fsWriteDenied = error.code === 'ERR_ACCESS_DENIED'; }\n" +
            "      try { const child = await import('node:child_process'); child.execFileSync(process.execPath, ['-e', '']); } catch (error) { denied.processDenied = error.code === 'ERR_ACCESS_DENIED'; }\n" +
            "      const net = await import('node:net');\n" +
            "      denied.networkDenied = await new Promise(resolve => { const client = net.createConnection({ host: '127.0.0.1', port: " + port.toString() + " }); let settled = false; const finish = denied => { if (settled) return; settled = true; client.destroy(); resolve(denied); }; client.once('connect', () => finish(false)); client.once('error', () => finish(true)); client.setTimeout(1000, () => finish(true)); });\n" +
            "      return { content: [{ type: 'text', text: JSON.stringify(denied) }], details: denied };\n" +
            "    }\n" +
            "  });\n" +
            "}\n"
        File.writeTo(root + "/probe.js", script.toArray())
        let descriptor = PluginPackageDescriptor(
            "pi-direct-access", "1.0.0", PluginEcosystem.Pi,
            PluginManifestFamily.Pi, "fixture", root: root,
            components: [PluginComponent(PluginComponentKind.Extension, "probe.js")],
            entrypoint: "probe.js"
        )
        let record = ProductPluginRecord(
            descriptor, PluginSourceKind.Local, root, "1.0.0", "", "", "", false, 0
        )
        let host = ProductJavaScriptPluginHost()
        try {
            let readyDeadline = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() + 5000
            while (!exists(Path(root + "/server-ready")) &&
                DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() < readyDeadline) {}
            @Expect(exists(Path(root + "/server-ready")), true)
            @Expect(host.mount(record).isOk(), true)
            let cancellation = CancellationSource()
            let result = match (host.invoke(
                descriptor.namespace, "probe", "{}",
                identity: JavaScriptHostInvocationIdentity(
                    threadId: "thread-pi-access", runId: "run-pi-access", epoch: 1,
                    operationId: "operation-pi-access", callId: "call-pi-access"
                ),
                cancellation: cancellation.token,
                cwd: root
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            cancellation.close()
            let json = stringifyUnifiedJson(result.value)
            @Expect(!result.isError && json.contains("\"fsReadDenied\":true"), true)
            @Expect(json.contains("\"fsWriteDenied\":true"), true)
            @Expect(json.contains("\"processDenied\":true"), true)
            @Expect(json.contains("\"networkDenied\":true"), true)
            @Expect(exists(Path(root + "/direct-write-probe")), false)
        } finally {
            let _ = host.unmount(descriptor.namespace)
            server.close()
            remove(root, recursive: true)
        }
    }
    @TestCase
    func piExtensionApiHostRestartsAfterPluginCrash(): Unit {
        let root = pluginContractTemp("pi-crash-restart")
        Directory.create(root, recursive: true)
        let script =
            "import { Type } from 'typebox';\n" +
            "let calls = 0;\n" +
            "export default function (pi) {\n" +
            "  pi.registerTool({ name: 'recover', label: 'Recover', description: 'Verify host restart',\n" +
            "    parameters: Type.Object({ action: Type.String() }),\n" +
            "    execute: async (_id, params) => {\n" +
            "      calls += 1;\n" +
            "      if (params.action === 'crash') process.exit(23);\n" +
            "      return { content: [{ type: 'text', text: 'recovered-' + calls }], details: {} };\n" +
            "    }\n" +
            "  });\n" +
            "}\n"
        File.writeTo(root + "/probe.js", script.toArray())
        let descriptor = PluginPackageDescriptor(
            "pi-crash-restart", "1.0.0", PluginEcosystem.Pi,
            PluginManifestFamily.Pi, "fixture", root: root,
            components: [PluginComponent(PluginComponentKind.Extension, "probe.js")],
            entrypoint: "probe.js"
        )
        let record = ProductPluginRecord(
            descriptor, PluginSourceKind.Local, root, "1.0.0", "", "", "", false, 0
        )
        let host = ProductJavaScriptPluginHost()
        try {
            @Expect(host.mount(record).isOk(), true)
            let cancellation = CancellationSource()
            let crashed = host.invoke(
                descriptor.namespace, "recover", "{\"action\":\"crash\"}",
                identity: JavaScriptHostInvocationIdentity(
                    threadId: "thread-pi-restart", runId: "run-pi-restart", epoch: 1,
                    operationId: "operation-pi-crash", callId: "call-pi-crash"
                ),
                cancellation: cancellation.token,
                cwd: root
            )
            @Expect(crashed.isOk(), false)
            let recovered = match (host.invoke(
                descriptor.namespace, "recover", "{\"action\":\"continue\"}",
                identity: JavaScriptHostInvocationIdentity(
                    threadId: "thread-pi-restart", runId: "run-pi-restart", epoch: 1,
                    operationId: "operation-pi-recover", callId: "call-pi-recover"
                ),
                cancellation: cancellation.token,
                cwd: root
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            cancellation.close()
            @Expect(!recovered.isError && stringifyUnifiedJson(recovered.value).contains("recovered-1"), true)
            @Expect(host.close().isOk(), true)
            @Expect(host.commands().size, 0)
            @Expect(match (host.mount(record)) {
                case Result.Err(error) => error.code == "plugin.host_closed"
                case Result.Ok(_) => false
            }, true)
            let afterCloseCancellation = CancellationSource()
            let afterClose = host.invoke(
                descriptor.namespace, "recover", "{\"action\":\"continue\"}",
                identity: JavaScriptHostInvocationIdentity(
                    threadId: "thread-pi-restart", runId: "run-pi-restart", epoch: 1,
                    operationId: "operation-pi-after-close", callId: "call-pi-after-close"
                ),
                cancellation: afterCloseCancellation.token,
                cwd: root
            )
            @Expect(match (afterClose) {
                case Result.Err(error) => error.code == "plugin.not_active"
                case Result.Ok(_) => false
            }, true)
            afterCloseCancellation.close()
        } finally {
            let _ = host.close()
            remove(root, recursive: true)
        }
    }

    @TestCase
    func piExtensionApiHostCancellationAndRevocationAreTerminal(): Unit {
        let root = pluginContractTemp("pi-cancel-restart")
        Directory.create(root, recursive: true)
        let markerPath = root + "/service-requested"
        let script =
            "import { Type } from 'typebox';\n" +
            "export default function (pi) {\n" +
            "  pi.registerTool({ name: 'wait', label: 'Wait', description: 'Verify broker cancellation',\n" +
            "    parameters: Type.Object({ action: Type.String() }),\n" +
            "    execute: async (_id, params) => {\n" +
            "      if (params.action === 'wait') await pi.exec('cat', ['request.txt']);\n" +
            "      return { content: [{ type: 'text', text: 'completed' }], details: {} };\n" +
            "    }\n" +
            "  });\n" +
            "}\n"
        File.writeTo(root + "/probe.js", script.toArray())
        let descriptor = PluginPackageDescriptor(
            "pi-cancel-restart", "1.0.0", PluginEcosystem.Pi,
            PluginManifestFamily.Pi, "fixture", root: root,
            components: [PluginComponent(PluginComponentKind.Extension, "probe.js")],
            entrypoint: "probe.js"
        )
        let record = ProductPluginRecord(
            descriptor, PluginSourceKind.Local, root, "1.0.0", "", "", "", false, 0
        )
        let host = ProductJavaScriptPluginHost()
        let observer = DelayedPiServiceObserver(markerPath)
        try {
            @Expect(host.mount(record).isOk(), true)
            let cancellation = CancellationSource()
            let startedAt = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
            let pending = spawn {
                host.invoke(
                    descriptor.namespace, "wait", "{\"action\":\"wait\"}",
                    identity: JavaScriptHostInvocationIdentity(
                        threadId: "thread-pi-cancel", runId: "run-pi-cancel", epoch: 1,
                        operationId: "operation-pi-wait", callId: "call-pi-wait"
                    ),
                    cancellation: cancellation.token,
                    cwd: root,
                    observer: Some(observer)
                )
            }
            let requestDeadline = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() + 5000
            while (!exists(Path(markerPath)) &&
                DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() < requestDeadline) {
                sleep(Duration.millisecond * 5)
            }
            let serviceRequestObserved = exists(Path(markerPath))
            let _ = cancellation.cancel()
            let cancelled = pending.get()
            let elapsed = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() - startedAt
            @Expect(serviceRequestObserved, true)
            @Expect(cancelled.isOk(), false)
            @Expect(elapsed < 2000, true)
            cancellation.close()

            let nextCancellation = CancellationSource()
            let next = match (host.invoke(
                descriptor.namespace, "wait", "{\"action\":\"continue\"}",
                identity: JavaScriptHostInvocationIdentity(
                    threadId: "thread-pi-cancel", runId: "run-pi-cancel", epoch: 1,
                    operationId: "operation-pi-after-cancel", callId: "call-pi-after-cancel"
                ),
                cancellation: nextCancellation.token,
                cwd: root
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            nextCancellation.close()
            @Expect(!next.isError && stringifyUnifiedJson(next.value).contains("completed"), true)

            let revocationMarker = root + "/service-before-unmount"
            let revocationObserver = DelayedPiServiceObserver(revocationMarker)
            let revocationCancellation = CancellationSource()
            let revocationStartedAt = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
            let revoking = spawn {
                host.invoke(
                    descriptor.namespace, "wait", "{\"action\":\"wait\"}",
                    identity: JavaScriptHostInvocationIdentity(
                        threadId: "thread-pi-revoke", runId: "run-pi-revoke", epoch: 1,
                        operationId: "operation-pi-revoke", callId: "call-pi-revoke"
                    ),
                    cancellation: revocationCancellation.token,
                    cwd: root,
                    observer: Some(revocationObserver)
                )
            }
            let revocationDeadline = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() + 5000
            while (!exists(Path(revocationMarker)) &&
                DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() < revocationDeadline) {
                sleep(Duration.millisecond * 5)
            }
            let invocationObserved = exists(Path(revocationMarker))
            let _ = host.unmount(descriptor.namespace)
            let revoked = revoking.get()
            let revocationElapsed = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() - revocationStartedAt
            @Expect(invocationObserved, true)
            @Expect(match (revoked) {
                case Result.Err(error) => error.code == "extension.cancelled"
                case Result.Ok(_) => false
            }, true)
            @Expect(revocationElapsed < 2000, true)
            revocationCancellation.close()

            let afterRevocationCancellation = CancellationSource()
            let afterRevocation = host.invoke(
                descriptor.namespace, "wait", "{\"action\":\"continue\"}",
                identity: JavaScriptHostInvocationIdentity(
                    threadId: "thread-pi-revoke", runId: "run-pi-revoke", epoch: 1,
                    operationId: "operation-pi-after-revoke", callId: "call-pi-after-revoke"
                ),
                cancellation: afterRevocationCancellation.token,
                cwd: root
            )
            @Expect(match (afterRevocation) {
                case Result.Err(error) => error.code == "plugin.not_active"
                case Result.Ok(_) => false
            }, true)
            afterRevocationCancellation.close()
        } finally {
            let _ = host.unmount(descriptor.namespace)
            remove(root, recursive: true)
        }
    }

    @TestCase
    func piExtensionHostRestartsQueuedCallAfterCancellation(): Unit {
        let root = pluginContractTemp("pi-queued-restart")
        Directory.create(root, recursive: true)
        let markerPath = root + "/first-progress"
        let script =
            "import { Type } from 'typebox';\n" +
            "export default function (pi) { let active = 0; let peak = 0;\n" +
            "  pi.registerTool({ name: 'serial', label: 'Serial', description: 'Concurrency contract',\n" +
            "    parameters: Type.Object({ token: Type.String() }),\n" +
            "    execute: async (_id, params, _signal, onUpdate) => {\n" +
            "      active++; peak = Math.max(peak, active); onUpdate({ content: [{ type: 'text', text: params.token }] });\n" +
            "      await new Promise(resolve => setTimeout(resolve, 500)); active--;\n" +
            "      return { content: [{ type: 'text', text: params.token }], details: { peakActive: peak } };\n" +
            "    } });\n" +
            "}\n"
        File.writeTo(root + "/probe.js", script.toArray())
        let descriptor = PluginPackageDescriptor(
            "pi-serialized-calls", "1.0.0", PluginEcosystem.Pi,
            PluginManifestFamily.Pi, "fixture", root: root,
            components: [PluginComponent(PluginComponentKind.Extension, "probe.js")],
            entrypoint: "probe.js"
        )
        let record = ProductPluginRecord(
            descriptor, PluginSourceKind.Local, root, "1.0.0", "", "", "", false, 0
        )
        let host = ProductJavaScriptPluginHost()
        let observer = PiProgressMarkerObserver(markerPath)
        let firstCancellation = CancellationSource()
        let secondCancellation = CancellationSource()
        try {
            @Expect(host.mount(record).isOk(), true)
            let first = spawn {
                host.invoke(
                    descriptor.namespace, "serial", "{\"token\":\"first\"}",
                    identity: JavaScriptHostInvocationIdentity(
                        threadId: "thread-pi-serial", runId: "run-pi-serial", epoch: 1,
                        operationId: "operation-pi-serial-first", callId: "call-pi-serial-first"
                    ),
                    cancellation: firstCancellation.token,
                    cwd: root,
                    observer: Some(observer)
                )
            }
            let progressDeadline = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() + 5000
            while (!exists(Path(markerPath)) &&
                DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() < progressDeadline) {
                sleep(Duration.millisecond * 5)
            }
            @Expect(exists(Path(markerPath)), true)
            let second = spawn {
                host.invoke(
                    descriptor.namespace, "serial", "{\"token\":\"second\"}",
                    identity: JavaScriptHostInvocationIdentity(
                        threadId: "thread-pi-serial", runId: "run-pi-serial", epoch: 1,
                        operationId: "operation-pi-serial-second", callId: "call-pi-serial-second"
                    ),
                    cancellation: secondCancellation.token,
                    cwd: root,
                    observer: Some(observer)
                )
            }
            sleep(Duration.millisecond * 100)
            let _ = firstCancellation.cancel()
            let firstResult = first.get()
            let secondResult = second.get()
            @Expect(match (firstResult) {
                case Result.Err(error) => error.code == "extension.cancelled"
                case Result.Ok(_) => false
            }, true)
            let secondJson = match (secondResult) {
                case Result.Ok(value) => stringifyUnifiedJson(value.value)
                case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            @Expect(secondJson.contains("second"), true)
            @Expect(secondJson.contains("\"peakActive\":1"), true)
        } finally {
            firstCancellation.close()
            secondCancellation.close()
            let _ = host.unmount(descriptor.namespace)
            remove(root, recursive: true)
        }
    }

    @TestCase
    func piExtensionInitializationDiagnosticRedactsPackagePath(): Unit {
        let root = pluginContractTemp("pi-error-redaction")
        Directory.create(root, recursive: true)
        File.writeTo(root + "/probe.js",
            "throw new Error(process.cwd() + '/redaction-sentinel');\n".toArray())
        let descriptor = PluginPackageDescriptor(
            "pi-error-redaction", "1.0.0", PluginEcosystem.Pi,
            PluginManifestFamily.Pi, "fixture", root: root,
            components: [PluginComponent(PluginComponentKind.Extension, "probe.js")],
            entrypoint: "probe.js"
        )
        let record = ProductPluginRecord(
            descriptor, PluginSourceKind.Local, root, "1.0.0", "", "", "", false, 0
        )
        let host = ProductJavaScriptPluginHost()
        try {
            let mounted = host.mount(record)
            @Expect(mounted.isOk(), false)
            let message = match (mounted) {
                case Result.Err(error) => error.message
                case Result.Ok(_) => "unexpected mount success"
            }
            @Expect(message.contains(root), false)
            @Expect(message.contains("<plugin>/redaction-sentinel"), true)
            @Expect(host.toolNames(descriptor.namespace).isEmpty(), true)
        } finally {
            let _ = host.unmount(descriptor.namespace)
            remove(root, recursive: true)
        }
    }

    @TestCase
    func javascriptPluginToolsCommitAsOneFrozenCatalogBatch(): Unit {
        let root = pluginContractTemp("transactional-registry")
        Directory.create(root, recursive: true)
        let script =
            "import { Type } from 'typebox';\n" +
            "export default function (pi) {\n" +
            "  for (const [name, text] of [['first', 'First tool'], ['second', 'Second tool']]) {\n" +
            "    pi.registerTool({ name, label: text, description: text, parameters: Type.Object({}),\n" +
            "      execute: async () => ({ content: [{ type: 'text', text }], details: {} }) });\n" +
            "  }\n" +
            "}\n"
        File.writeTo(root + "/probe.js", script.toArray())
        let descriptor = PluginPackageDescriptor(
            "transactional-extension", "1.0.0", PluginEcosystem.Pi,
            PluginManifestFamily.Pi, "fixture", root: root,
            components: [PluginComponent(PluginComponentKind.Extension, "probe.js")],
            entrypoint: "probe.js", requestedCapabilities: ["workspace.read"],
            contentDigest: "fixture-digest-v1"
        )
        let record = ProductPluginRecord(
            descriptor, PluginSourceKind.Local, root, "1.0.0", "", "", "", false, 0
        )
        let host = ProductJavaScriptPluginHost()
        let catalog = ToolCatalog()
        let runCapabilities = CapabilitySet(values: [
            Capability(CapabilityKind.ExtensionInvoke),
            Capability(CapabilityKind.WorkspaceRead)
        ])
        let noReadCapabilities = CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke)])
        let frozenBeforeActivation = catalog.toolSetSnapshot("active-run-before-plugin", runCapabilities)
        let firstName = "plugin." + descriptor.namespace + ".first"
        let secondName = "plugin." + descriptor.namespace + ".second"
        try {
            match (mountAndRegisterJavaScriptPlugin(record, host, catalog)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            let definitions = catalog.definitions()
            @Expect(definitions.size, 2)
            @Expect(definitions[0].name, firstName)
            @Expect(definitions[1].name, secondName)
            @Expect(host.toolNames(descriptor.namespace), ["first", "second"])
            @Expect(frozenBeforeActivation.entries.isEmpty(), true)
            let nextRun = catalog.toolSetSnapshot("next-run-after-plugin", runCapabilities)
            let restrictedSnapshot = catalog.toolSetSnapshot(
                "plugin-without-workspace-read", noReadCapabilities
            )
            @Expect(restrictedSnapshot.entries.size, 2)
            @Expect(restrictedSnapshot.entries[0].availableAtSnapshot, false)
            @Expect(restrictedSnapshot.entries[1].availableAtSnapshot, false)
            @Expect(nextRun.entries.size, 2)
            @Expect(match (catalog.resolvedDescriptor(ToolCall("registry-call", firstName, objectValue([])))) {
                case Some(tool) =>
                    let required = tool.requiredCapabilities()
                    required.size == 2 &&
                        required[0].kind == CapabilityKind.ExtensionInvoke &&
                        required[1].kind == CapabilityKind.WorkspaceRead
                case None => false
            }, true)

            let conflictHost = ProductJavaScriptPluginHost()
            let conflictCatalog = ToolCatalog()
            let existing = ToolDescriptor(
                ModelToolDefinition(secondName, "Existing collision",
                    objectValue([ValueField("type", textValue("object"))])),
                Capability(CapabilityKind.ExtensionInvoke),
                sideEffecting: true
            )
            @Expect(conflictCatalog.register(
                existing, ProductJavaScriptPluginToolExecutor(
                    ProductJavaScriptPluginHost(), descriptor.namespace, "second"
                )
            ).isOk(), true)
            let rejected = mountAndRegisterJavaScriptPlugin(record, conflictHost, conflictCatalog)
            @Expect(match (rejected) {
                case Result.Err(error) => error.code == "tool.duplicate"
                case Result.Ok(_) => false
            }, true)
            @Expect(conflictCatalog.definitions().size, 1)
            @Expect(conflictCatalog.definitions()[0].name, secondName)
            @Expect(conflictHost.toolNames(descriptor.namespace).isEmpty(), true)
            let _ = conflictHost.unmount(descriptor.namespace)
        } finally {
            let _ = host.unmount(descriptor.namespace)
            remove(root, recursive: true)
        }
    }

    @TestCase
    func diagnosticsReportBrokenRootsAndFloatingLocks(): Unit {
        let root = pluginContractTemp("diagnostics")
        let settings = root + "/settings"
        Directory.create(root)
        Directory.create(settings + "/plugins", recursive: true)
        File.writeTo(root + "/package.json", "{\"name\":\"diagnostic-plugin\",\"version\":\"1.0.0\",\"pi\":{\"skills\":[\"skills\"]}}".toArray())
        let floatingLock = "{\"id\":\"diagnostic-plugin\",\"version\":\"1.0.0\",\"source_kind\":\"git\",\"locator\":\"https://example.test/plugin.git\",\"root\":\"" + root + "\",\"version_lock\":\"\",\"revision\":\"\",\"integrity\":\"\",\"enabled\":false}"
        File.writeTo(settings + "/plugins/lock.jsonl", floatingLock.toArray())
        let runtime = ProductPluginRuntime(settings, root)
        var hasUnpinned = false
        for (error in runtime.doctor()) {
            if (error.code == "plugin.source_unpinned") { hasUnpinned = true }
        }
        @Expect(hasUnpinned, true)

        let missingRoot = root + "/missing-package"
        Directory.create(root + "/missing-settings/plugins", recursive: true)
        let missingLock = "{\"id\":\"missing-plugin\",\"version\":\"1.0.0\",\"source_kind\":\"local\",\"locator\":\"" + missingRoot + "\",\"root\":\"" + missingRoot + "\",\"enabled\":false}"
        File.writeTo(root + "/missing-settings/plugins/lock.jsonl", missingLock.toArray())
        let reloadedMissing = ProductPluginRuntime(root + "/missing-settings", root)
        var hasMissing = false
        for (error in reloadedMissing.diagnostics()) {
            if (error.code == "plugin.root_missing" || error.code == "plugin.package_missing") { hasMissing = true }
        }
        @Expect(hasMissing, true)
    }
    @TestCase
    func workspacePluginScopeOverridesUserAndExplicitDisableWins(): Unit {
        let workspace = pluginContractTemp("scope-workspace")
        let settings = pluginContractTemp("scope-settings")
        let userPackage = pluginContractTemp("scope-user-plugin")
        let workspacePackage = pluginContractTemp("scope-workspace-plugin")
        for (root in [userPackage, workspacePackage]) {
            Directory.create(root + "/skills/demo", recursive: true)
            File.writeTo(root + "/skills/demo/SKILL.md",
                "---\nname: Scoped demo\ndescription: Scoped fixture\n---\nScoped instructions.\n".toArray())
            File.writeTo(root + "/package.json",
                "{\"name\":\"scoped-plugin\",\"version\":\"1.0.0\",\"pi\":{\"skills\":[\"skills\"]}}".toArray())
        }
        File.writeTo(workspacePackage + "/package.json",
            "{\"name\":\"scoped-plugin\",\"version\":\"2.0.0\",\"pi\":{\"skills\":[\"skills\"]}}".toArray())
        let runtime = ProductPluginRuntime(settings, workspace)
        let user = match (runtime.importLocal(userPackage)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        let project = match (runtime.importLocal(workspacePackage, PluginInstallScope.Workspace)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        @Expect(exists(Path(settings + "/plugins/lock.jsonl")), true)
        @Expect(exists(Path(workspace + "/.axyndra/plugins/lock.jsonl")), true)
        @Expect(user.descriptor.root != project.descriptor.root, true)
        @Expect(runtime.list().size, 2)
        @Expect(match (runtime.get("scoped-plugin")) {
            case Some(value) => value.descriptor.version == "2.0.0"
            case None => false
        }, true)
        var reportsShadow = false
        for (error in runtime.diagnostics()) {
            if (error.code == "plugin.scope_shadowed") { reportsShadow = true }
        }
        @Expect(reportsShadow, true)

        match (runtime.setEnabled("scoped-plugin", true, PluginInstallScope.Workspace)) {
            case PluginImportResult.Ok(_) => ()
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        @Expect(runtime.enabledSkillRoots().size, 1)
        match (runtime.setEnabled("scoped-plugin", false, PluginInstallScope.User)) {
            case PluginImportResult.Ok(_) => ()
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        @Expect(runtime.enabledSkillRoots().isEmpty(), true)
        let reloaded = ProductPluginRuntime(settings, workspace)
        @Expect(reloaded.list().size, 2)
        @Expect(match (reloaded.get("scoped-plugin")) {
            case Some(value) => match (value.scope) {
                case PluginInstallScope.User => value.explicitlyDisabled
                case PluginInstallScope.Workspace => false
            }
            case None => false
        }, true)
        @Expect(reloaded.enabledSkillRoots().isEmpty(), true)
    }
    @TestCase
    func updateRollbackUninstallAndGarbageCollectionAreTransactional(): Unit {
        let firstRoot = pluginContractTemp("update-first")
        let secondRoot = pluginContractTemp("update-second")
        let settings = pluginContractTemp("update-settings")
        Directory.create(firstRoot)
        Directory.create(secondRoot)
        Directory.create(firstRoot + "/skills/demo/references", recursive: true)
        Directory.create(secondRoot + "/skills/demo/references", recursive: true)
        File.writeTo(firstRoot + "/package.json",
            "{\"name\":\"lifecycle-plugin\",\"version\":\"1.0.0\",\"pi\":{\"skills\":[\"skills\"]}}".toArray())
        File.writeTo(secondRoot + "/package.json",
            "{\"name\":\"lifecycle-plugin\",\"version\":\"2.0.0\",\"pi\":{\"skills\":[\"skills\"]}}".toArray())
        for ((root, version) in [(firstRoot, "v1"), (secondRoot, "v2")]) {
            File.writeTo(root + "/skills/demo/SKILL.md",
                "---\nname: Lifecycle demo\ndescription: Lifecycle fixture\ntriggers: lifecycle\n---\nRead [guide](references/guide.md).\n".toArray())
            File.writeTo(root + "/skills/demo/references/guide.md", version.toArray())
        }
        let runtime = ProductPluginRuntime(settings, firstRoot)
        @Expect(runtime.importLocal(firstRoot).isOk(), true)
        let firstSnapshot = runtime.list()[0].descriptor.root
        match (runtime.setEnabled("lifecycle-plugin", true)) {
            case PluginImportResult.Ok(_) => ()
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        let skills = ProductSkillRuntime(settings, firstRoot, pluginRuntime: Some(runtime))
        let frozenSkillSnapshot = skills.resolve("use lifecycle", SkillStackSnapshot([], []))
        @Expect(frozenSkillSnapshot.active.size, 1)
        @Expect(match (runtime.updateLocal("lifecycle-plugin", secondRoot)) {
            case PluginImportResult.Ok(record) => record.descriptor.version == "2.0.0"
            case PluginImportResult.Err(_) => false
        }, true)
        let secondSnapshot = runtime.list()[0].descriptor.root
        @Expect(runtime.list()[0].descriptor.version, "2.0.0")
        @Expect(match (skills.readReference(frozenSkillSnapshot, "demo", "guide.md")) {
            case Result.Ok(reference) => reference.content == "v1"
            case Result.Err(_) => false
        }, true)

        let stale = pluginSnapshotPackageRoot(
            settings, firstRoot, PluginInstallScope.User
        ) + "/stale-generation"
        Directory.create(stale, recursive: true)
        File.writeTo(stale + "/marker", "stale".toArray())
        @Expect(match (runtime.garbageCollect()) {
            case PluginImportResult.Ok(paths) => paths.size == 1 && !exists(Path(stale))
            case PluginImportResult.Err(_) => false
        }, true)
        @Expect(exists(Path(firstSnapshot)), true)
        @Expect(exists(Path(secondSnapshot)), true)

        @Expect(match (runtime.updateLocal("lifecycle-plugin", firstRoot + "/missing")) {
            case PluginImportResult.Err(_) => true
            case PluginImportResult.Ok(_) => false
        }, true)
        @Expect(runtime.list()[0].descriptor.version, "2.0.0")
        @Expect(match (runtime.rollback("lifecycle-plugin")) {
            case PluginImportResult.Ok(record) => record.descriptor.version == "1.0.0"
            case PluginImportResult.Err(_) => false
        }, true)
        @Expect(runtime.list()[0].descriptor.version, "1.0.0")
        @Expect(runtime.list()[0].descriptor.root, firstSnapshot)
        @Expect(exists(Path(secondSnapshot)), true)

        @Expect(match (runtime.uninstall("lifecycle-plugin")) {
            case PluginImportResult.Ok(_) => true
            case PluginImportResult.Err(_) => false
        }, true)
        @Expect(runtime.list().isEmpty(), true)
        @Expect(match (runtime.garbageCollect()) {
            case PluginImportResult.Ok(paths) => paths.isEmpty() &&
                exists(Path(firstSnapshot)) && exists(Path(secondSnapshot))
            case PluginImportResult.Err(_) => false
        }, true)
        @Expect(match (skills.readReference(frozenSkillSnapshot, "demo", "guide.md")) {
            case Result.Ok(reference) => reference.content == "v1"
            case Result.Err(_) => false
        }, true)
    }
    @TestCase
    func workspaceGarbageCollectionDoesNotCrossWorkspaceCaches(): Unit {
        let settings = pluginContractTemp("shared-gc-settings")
        let workspaceA = pluginContractTemp("shared-gc-workspace-a")
        let workspaceB = pluginContractTemp("shared-gc-workspace-b")
        let sourceA = pluginContractTemp("shared-gc-source-a")
        let sourceB = pluginContractTemp("shared-gc-source-b")
        for (path in [workspaceA, workspaceB, sourceA, sourceB]) {
            Directory.create(path, recursive: true)
        }
        File.writeTo(sourceA + "/package.json",
            "{\"name\":\"gc-workspace-a\",\"version\":\"1.0.0\",\"pi\":{}}".toArray())
        File.writeTo(sourceB + "/package.json",
            "{\"name\":\"gc-workspace-b\",\"version\":\"1.0.0\",\"pi\":{}}".toArray())
        let runtimeA = ProductPluginRuntime(settings, workspaceA)
        let runtimeB = ProductPluginRuntime(settings, workspaceB)
        let importedA = match (runtimeA.importLocal(sourceA, PluginInstallScope.Workspace)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        let importedB = match (runtimeB.importLocal(sourceB, PluginInstallScope.Workspace)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        let staleA = pluginSnapshotPackageRoot(
            settings, workspaceA, PluginInstallScope.Workspace
        ) + "/stale-generation"
        Directory.create(staleA, recursive: true)
        File.writeTo(staleA + "/marker", "stale".toArray())
        @Expect(match (runtimeA.garbageCollect()) {
            case PluginImportResult.Ok(paths) => paths.size == 1 && !exists(Path(staleA))
            case PluginImportResult.Err(_) => false
        }, true)
        @Expect(exists(Path(importedA.descriptor.root)), true)
        @Expect(exists(Path(importedB.descriptor.root)), true)
        @Expect(ProductPluginRuntime(settings, workspaceB).list().size, 1)
    }

    @TestCase
    func rollbackHistorySurvivesRuntimeRestart(): Unit {
        let firstRoot = pluginContractTemp("restart-first")
        let secondRoot = pluginContractTemp("restart-second")
        let settings = pluginContractTemp("restart-settings")
        Directory.create(firstRoot)
        Directory.create(secondRoot)
        File.writeTo(firstRoot + "/package.json",
            "{\"name\":\"restart-plugin\",\"version\":\"1.0.0\",\"pi\":{\"skills\":[\"skills\"]}}".toArray())
        File.writeTo(secondRoot + "/package.json",
            "{\"name\":\"restart-plugin\",\"version\":\"2.0.0\",\"pi\":{\"skills\":[\"skills\"]}}".toArray())
        let runtime = ProductPluginRuntime(settings, firstRoot)
        @Expect(runtime.importLocal(firstRoot).isOk(), true)
        @Expect(runtime.updateLocal("restart-plugin", secondRoot).isOk(), true)
        remove(Path(firstRoot), recursive: true)

        let restarted = ProductPluginRuntime(settings, secondRoot)
        @Expect(match (restarted.rollback("restart-plugin")) {
            case PluginImportResult.Ok(record) => record.descriptor.version == "1.0.0"
            case PluginImportResult.Err(_) => false
        }, true)
        let restoredRoot = restarted.list()[0].descriptor.root
        @Expect(restoredRoot != firstRoot, true)
        @Expect(exists(Path(restoredRoot + "/package.json")), true)
    }
    @TestCase
    func persistentJavaScriptHostRejectsUnenforceablePerCallResourceLimits(): Unit {
        let host = ProductJavaScriptPluginHost()
        let identity = JavaScriptHostInvocationIdentity(
            threadId: "thread-budget",
            runId: "run-budget",
            epoch: 1,
            operationId: "operation-budget",
            callId: "call-budget"
        )
        let cancellation = CancellationSource()
        let rejected = host.invoke(
            "inactive", "echo", "{}",
            identity: identity,
            cancellation: cancellation.token,
            processLimits: ExecutionResourceLimits(openFiles: 128)
        )
        @Expect(match (rejected) {
            case Result.Err(error) => error.code == "plugin.resource_limit_unavailable"
            case Result.Ok(_) => false
        }, true)
        let inherited = host.invoke(
            "inactive", "echo", "{}",
            identity: identity,
            cancellation: cancellation.token,
            processLimits: ExecutionResourceLimits()
        )
        @Expect(match (inherited) {
            case Result.Err(error) => error.code == "plugin.not_active"
            case Result.Ok(_) => false
        }, true)
    }

    @TestCase
    func productJavaScriptHostUsesOSIsolationWithoutNodePermissions(): Unit {
        let cacheRoot = homeDirectory() + "/.cache/agent-tmp"
        if (!exists(Path(cacheRoot))) { Directory.create(cacheRoot, recursive: true) }
        let root = cacheRoot + "/axyndra-plugin-os-sandbox-" +
            DateTime.nowUTC().toUnixTimeStamp().toMilliseconds().toString()
        Directory.create(root, recursive: true)
        let port = 40000 + DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() % 20000
        let serverSource =
            "const fs=require('node:fs');const net=require('node:net');" +
            "const server=net.createServer(socket=>socket.end('reachable'));" +
            "server.once('error',()=>process.exit(2));" +
            "server.listen(" + port.toString() + ",'127.0.0.1',()=>" +
            "fs.writeFileSync('server-ready','ready'));"
        let server = process.startProcess(process.ProcessCommand(
            "node",
            arguments: ["-e", serverSource],
            workingDirectory: root,
            maxOutputBytes: 4096
        ))
        try {
            let readyDeadline = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() + 5000
            while (!exists(Path(root + "/server-ready")) &&
                DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() < readyDeadline) {}
            @Expect(exists(Path(root + "/server-ready")), true)

            let script =
                "const fs=require('node:fs');const net=require('node:net');" +
                "const readline=require('node:readline');" +
                "function send(message){process.stdout.write(JSON.stringify(message)+String.fromCharCode(10));}" +
                "function envelope(type,m){return {type,protocol:m.protocol,extension_id:m.extension_id," +
                "extension_version:m.extension_version,generation:m.generation,id:m.id,tool:m.tool," +
                "thread_id:m.thread_id,run_id:m.run_id,epoch:m.epoch,operation_id:m.operation_id,call_id:m.call_id};}" +
                "async function probe(message){let filesystemDenied=false;" +
                "try{fs.writeFileSync(process.cwd()+'/os-sandbox-write-probe','unsafe');}" +
                "catch(_){filesystemDenied=true;}" +
                "const networkDenied=await new Promise(resolve=>{" +
                "const client=net.createConnection({host:'127.0.0.1',port:" + port.toString() + "});" +
                "let settled=false;const finish=value=>{if(settled)return;settled=true;client.destroy();resolve(value);};" +
                "client.once('connect',()=>finish(false));client.once('error',()=>finish(true));" +
                "client.setTimeout(1000,()=>finish(true));});" +
                "send({...envelope('result',message),ok:true,result:{filesystemDenied,networkDenied}});}" +
                "readline.createInterface({input:process.stdin,crlfDelay:Infinity}).on('line',line=>{" +
                "const message=JSON.parse(line);if(message.type==='hello'){send({type:'ready'," +
                "protocol:message.protocol,extension_id:message.extension_id," +
                "extension_version:message.extension_version,generation:message.generation," +
                "capabilities:message.capabilities,tools:[{name:'probe'," +
                "input_schema:{type:'object'}}]});}else if(message.type==='invoke'){probe(message);}" +
                "else if(message.type==='close'){process.exit(0);}});"
            File.writeTo(root + "/probe.js", script.toArray())
            let host = match (startJavaScriptExtensionHostWithLauncher(
                JavaScriptHostLaunchRequest(
                    root,
                    "probe.js",
                    extensionId: "product.os-sandbox",
                    extensionVersion: "1.0.0",
                    enforceNodePermissions: false
                ),
                ProductSandboxedJavaScriptHostLauncher()
            )) {
                case JavaScriptHostResult.Ok(value) => value
                case JavaScriptHostResult.Err(error) =>
                    throw IllegalStateException(error.code + ": " + error.message)
            }
            try {
                let result = match (host.invoke(
                    "probe",
                    "{}",
                    identity: JavaScriptHostInvocationIdentity(
                        threadId: "thread-product",
                        runId: "run-product",
                        epoch: 1,
                        operationId: "operation-product",
                        callId: "call-product"
                    )
                )) {
                    case JavaScriptHostResult.Ok(value) => value
                    case JavaScriptHostResult.Err(error) =>
                        throw IllegalStateException(error.code + ": " + error.message)
                }
                @Expect(result.resultJson.contains("\"filesystemDenied\":true"), true)
                @Expect(result.resultJson.contains("\"networkDenied\":true"), true)
                @Expect(exists(Path(root + "/os-sandbox-write-probe")), false)
            } finally {
                host.close()
            }
        } finally {
            server.close()
            remove(root, recursive: true)
        }
    }
    @TestCase
    func pluginSnapshotsPreserveAndDigestExecutablePermission(): Unit {
        let source = pluginContractTemp("snapshot-mode-source")
        let settings = pluginContractTemp("snapshot-mode-settings")
        Directory.create(source, recursive: true)
        File.writeTo(source + "/package.json",
            "{\"name\":\"snapshot-mode\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"run.sh\"]}}".toArray())
        File.writeTo(source + "/run.sh", "#!/bin/sh\nexit 0\n".toArray())
        let sourceInfo = FileInfo(Path(source + "/run.sh"))
        let _ = sourceInfo.setExecutable(true)
        let executableDigest = match (inspectPluginPackage(source)) {
            case PluginPackageResult.Ok(value) => value.contentDigest
            case PluginPackageResult.Err(error) => throw IllegalStateException(error.code)
        }
        let _ = sourceInfo.setExecutable(false)
        let nonExecutableDigest = match (inspectPluginPackage(source)) {
            case PluginPackageResult.Ok(value) => value.contentDigest
            case PluginPackageResult.Err(error) => throw IllegalStateException(error.code)
        }
        @Expect(executableDigest != nonExecutableDigest, true)
        let _ = sourceInfo.setExecutable(true)
        let imported = match (ProductPluginRuntime(settings, source).importLocal(source)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        @Expect(FileInfo(Path(imported.descriptor.root + "/run.sh")).canExecute(), true)
    }

    @TestCase
    func localPluginImportRejectsSymlinkedSourceAncestor(): Unit {
        let root = pluginContractTemp("plugin-source-symlink-ancestor")
        let settings = root + "/settings"
        let workspace = root + "/workspace"
        let external = root + "/external"
        let packageRoot = external + "/package"
        Directory.create(settings, recursive: true)
        Directory.create(workspace, recursive: true)
        Directory.create(packageRoot, recursive: true)
        File.writeTo(packageRoot + "/plugin.json",
            "{\"name\":\"source-link-plugin\",\"version\":\"1.0.0\"}".toArray())
        SymbolicLink.create(root + "/source-link", to: external)
        try {
            @Expect(match (ProductPluginRuntime(settings, workspace).importLocal(
                root + "/source-link/package"
            )) {
                case PluginImportResult.Err(_) => true
                case PluginImportResult.Ok(_) => false
            }, true)
        } finally {
            remove(root, recursive: true)
        }
    }

    @TestCase
    func workspacePluginStorageRejectsSymlinkedMetadataAncestor(): Unit {
        let workspace = pluginContractTemp("symlink-workspace")
        let settings = pluginContractTemp("symlink-settings")
        let external = pluginContractTemp("symlink-external")
        let source = pluginContractTemp("symlink-source")
        Directory.create(workspace, recursive: true)
        Directory.create(external, recursive: true)
        Directory.create(source, recursive: true)
        File.writeTo(source + "/package.json",
            "{\"name\":\"symlink-cache\",\"version\":\"1.0.0\",\"pi\":{}}".toArray())
        SymbolicLink.create(workspace + "/.axyndra", to: external)
        let result = ProductPluginRuntime(settings, workspace).importLocal(
            source, PluginInstallScope.Workspace
        )
        @Expect(match (result) {
            case PluginImportResult.Err(error) => error.code == "plugin.lock_write_failed"
            case PluginImportResult.Ok(_) => false
        }, true)
        @Expect(exists(Path(external + "/plugins")), false)
    }

    @TestCase
    func pluginLockSerializationEscapesControlCharacters(): Unit {
        let base = pluginContractTemp("lock-controls")
        let settings = pluginContractTemp("lock-controls-settings")
        let source = base + "/source\twith\rcontrols"
        Directory.create(source, recursive: true)
        File.writeTo(source + "/package.json",
            "{\"name\":\"lock-controls\",\"version\":\"1.0.0\",\"pi\":{}}".toArray())
        let imported = ProductPluginRuntime(settings, base).importLocal(source)
        @Expect(imported.isOk(), true)
        let reloaded = ProductPluginRuntime(settings, base)
        @Expect(reloaded.list().size, 1)
        if (reloaded.list().size == 1) {
            @Expect(reloaded.list()[0].locator, source)
        }
    }

    @TestCase
    func restrictedPluginAcquisitionUsesEndpointBoundMediation(): Unit {
        let git = ProductPluginSourceEndpoint("git.example.test", 443u16, false)
        let registry = ProductPluginSourceEndpoint("registry.example.test", 443u16, false)
        let restricted = match (productPluginAcquisitionPolicy(
            ShellNetworkMode.Restricted,
            Some(git),
            registry,
            true
        )) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        @Expect(restricted.mode, NetworkPolicyMode.Mediated)
        @Expect(restricted.egress.size, 2)
        @Expect(restricted.egress[0].host, "git.example.test")
        @Expect(restricted.egress[0].port, 443u16)
        @Expect(restricted.egress[1].host, "registry.example.test")
        @Expect(restricted.egress[1].port, 443u16)

        let local = match (productPluginAcquisitionPolicy(
            ShellNetworkMode.Restricted,
            None,
            registry,
            false
        )) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        @Expect(local.mode, NetworkPolicyMode.Denied)

        let trusted = match (productPluginAcquisitionPolicy(
            ShellNetworkMode.TrustedHost,
            Some(git),
            registry,
            true
        )) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        @Expect(trusted.mode, NetworkPolicyMode.HostNetwork)
    }

    @TestCase
    func workspaceLockCannotSelfAuthorizePluginActivation(): Unit {
        let workspace = pluginContractTemp("workspace-consent")
        let settings = pluginContractTemp("workspace-consent-settings")
        let source = workspace + "/plugin"
        Directory.create(source + "/skills/demo", recursive: true)
        File.writeTo(source + "/skills/demo/SKILL.md",
            "---\nname: Consent demo\ndescription: Consent fixture\n---\nInstructions.\n".toArray())
        File.writeTo(source + "/package.json",
            "{\"name\":\"workspace-consent\",\"version\":\"1.0.0\",\"pi\":{\"skills\":[\"skills\"]}}".toArray())
        let runtime = ProductPluginRuntime(settings, workspace)
        let imported = match (runtime.importLocal(source, PluginInstallScope.Workspace)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        let lockPath = workspace + "/.axyndra/plugins/lock.jsonl"
        let attackerLock = String.fromUtf8(File.readFrom(Path(lockPath))).replace(
            "\"enabled\":false", "\"enabled\":true"
        )
        File.writeTo(lockPath, attackerLock.toArray())
        let untrusted = ProductPluginRuntime(settings, workspace)
        @Expect(untrusted.list()[0].enabled, false)
        match (untrusted.setEnabled(
            imported.descriptor.namespace, true, PluginInstallScope.Workspace
        )) {
            case PluginImportResult.Ok(_) => ()
            case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
        }
        let trusted = ProductPluginRuntime(settings, workspace)
        @Expect(trusted.list()[0].enabled, true)
        @Expect(trusted.enabledSkillRoots().size, 1)
    }

    @TestCase
    func piToolHooksRequireWorkspaceReadCapability(): Unit {
        let root = pluginContractTemp("hook-read-grant")
        Directory.create(root, recursive: true)
        File.writeTo(root + "/probe.js", (
            "export default function (pi) {\n" +
            "  pi.on('tool_result', () => ({ observed: true }));\n" +
            "}\n"
        ).toArray())
        let descriptor = PluginPackageDescriptor(
            "hook-read-grant", "1.0.0", PluginEcosystem.Pi,
            PluginManifestFamily.Pi, "fixture", root: root,
            components: [PluginComponent(PluginComponentKind.Extension, "probe.js")],
            entrypoint: "probe.js", contentDigest: "fixture-hook-read-grant"
        )
        let record = ProductPluginRecord(
            descriptor, PluginSourceKind.Local, root, "1.0.0", "", "", "", false, 0
        )
        let host = ProductJavaScriptPluginHost()
        let catalog = ToolCatalog()
        try {
            match (mountAndRegisterJavaScriptPlugin(record, host, catalog)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            let snapshot = catalog.toolSetSnapshot(
                "hook-read-grant", CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke)])
            )
            @Expect(snapshot.hookHandlers.isEmpty(), true)
        } finally {
            let _ = host.unmount(descriptor.namespace)
            remove(root, recursive: true)
        }
    }

    @TestCase
    func piToolCallHooksRequireWorkspaceWriteCapability(): Unit {
        let root = pluginContractTemp("hook-write-grant")
        Directory.create(root, recursive: true)
        File.writeTo(root + "/probe.js", (
            "export default function (pi) {\n" +
            "  pi.on('tool_call', event => ({ input: { path: 'changed' } }));\n" +
            "  pi.on('tool_result', () => ({ observed: true }));\n" +
            "}\n"
        ).toArray())
        let descriptor = PluginPackageDescriptor(
            "hook-write-grant", "1.0.0", PluginEcosystem.Pi,
            PluginManifestFamily.Pi, "fixture", root: root,
            components: [PluginComponent(PluginComponentKind.Extension, "probe.js")],
            entrypoint: "probe.js", requestedCapabilities: ["workspace.read"],
            contentDigest: "fixture-hook-write-grant"
        )
        let record = ProductPluginRecord(
            descriptor, PluginSourceKind.Local, root, "1.0.0", "", "", "", false, 0
        )
        let host = ProductJavaScriptPluginHost()
        let catalog = ToolCatalog()
        let cancellation = CancellationSource()
        try {
            match (mountAndRegisterJavaScriptPlugin(record, host, catalog)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            let snapshot = catalog.toolSetSnapshot(
                "hook-write-grant",
                CapabilitySet(values: [
                    Capability(CapabilityKind.ExtensionInvoke),
                    Capability(CapabilityKind.WorkspaceRead)
                ])
            )
            let scopedSnapshot = catalog.toolSetSnapshot(
                "hook-write-grant-scoped",
                CapabilitySet(values: [
                    Capability(CapabilityKind.ExtensionInvoke),
                    Capability(CapabilityKind.WorkspaceRead, resource: "/outside")
                ])
            )
            @Expect(scopedSnapshot.hookHandlers.isEmpty(), true)
            @Expect(snapshot.hookHandlers.size, 1)
            if (snapshot.hookHandlers.size == 1) {
                @Expect(snapshot.hookHandlers[0].event, "PostToolUse")
                let hookContext = ToolInvocationContext(
                    RunId("hook-scope-run"), SessionId("hook-scope-session"),
                    CapabilitySet(values: [
                        Capability(CapabilityKind.ExtensionInvoke),
                        Capability(CapabilityKind.WorkspaceRead)
                    ]),
                    cancellation: cancellation.token
                )
                @Expect(piHookMayObserveOperation(
                    hookContext,
                    snapshot.hookHandlers[0],
                    CoreToolHookPostEvent(
                        "read_file", objectValue([]), "operation-outside", "receipt-outside",
                        "completed", [Capability(CapabilityKind.WorkspaceRead, resource: "/outside")]
                    )
                ), false)
                @Expect(piHookMayObserveOperation(
                    hookContext,
                    snapshot.hookHandlers[0],
                    CoreToolHookPostEvent(
                        "read_file", objectValue([]), "operation-workspace", "receipt-workspace",
                        "completed", [Capability(CapabilityKind.WorkspaceRead)]
                    )
                ), true)
            }
        } finally {
            cancellation.close()
            let _ = host.unmount(descriptor.namespace)
            remove(root, recursive: true)
        }
    }

    @TestCase
    func codexHooksRequireExplicitWorkspaceCapabilities(): Unit {
        @Expect(codexHookGrantAllows("PreToolUse", []), false)
        @Expect(codexHookGrantAllows("PostToolUse", []), false)
        @Expect(codexHookGrantAllows(
            "PreToolUse", ["workspace.read"]
        ), false)
        @Expect(codexHookGrantAllows(
            "PostToolUse", ["workspace.read"]
        ), true)
        @Expect(codexHookGrantAllows(
            "PreToolUse", ["workspace.write"]
        ), true)
        @Expect(codexHookGrantAllows(
            "PostToolUse", ["workspace.write"]
        ), true)
    }

    @TestCase
    func codexHookRevocationRejectsSnapshotsAndCancelsActiveHandlers(): Unit {
        let root = pluginContractTemp("hook-revocation")
        Directory.create(root, recursive: true)
        let descriptor = PluginPackageDescriptor(
            "hook-revocation", "1.0.0", PluginEcosystem.Codex,
            PluginManifestFamily.Codex, "fixture", root: root,
            contentDigest: "hook-revocation-digest"
        )
        let record = ProductPluginRecord(
            descriptor, PluginSourceKind.Local, root, "1.0.0", "", "",
            descriptor.contentDigest, true, 0
        )
        let handler = ToolHookHandlerSnapshot(
            "PreToolUse",
            descriptor.namespace,
            descriptor.version,
            descriptor.contentDigest,
            descriptor.root,
            "*",
            "true",
            5000
        )
        let processes = LocalProcessPort(LocalWorkspace(root))
        let runtime = ProductCodexHookRuntime(
            processes, ProductJavaScriptPluginHost()
        )
        let parent = CancellationSource()
        try {
            runtime.activatePlugin(record)
            let active = runtime.beginHook(handler, parent.token).getOrThrow()
            @Expect(active.source.token.isCancelled(), false)
            runtime.revokePlugin(record)
            @Expect(active.source.token.isCancelled(), true)
            @Expect(runtime.beginHook(handler, parent.token).isNone(), true)
            runtime.endHook(active)

            runtime.activatePlugin(record)
            let restored = runtime.beginHook(handler, parent.token).getOrThrow()
            @Expect(restored.source.token.isCancelled(), false)

            let updatedDescriptor = PluginPackageDescriptor(
                "hook-revocation", "2.0.0", PluginEcosystem.Codex,
                PluginManifestFamily.Codex, "fixture", root: root,
                contentDigest: "hook-revocation-digest-v2"
            )
            let updatedRecord = ProductPluginRecord(
                updatedDescriptor, PluginSourceKind.Local, root, "2.0.0", "", "",
                updatedDescriptor.contentDigest, true, 0
            )
            let updatedHandler = ToolHookHandlerSnapshot(
                "PreToolUse",
                updatedDescriptor.namespace,
                updatedDescriptor.version,
                updatedDescriptor.contentDigest,
                updatedDescriptor.root,
                "*",
                "true",
                5000
            )
            runtime.activatePlugin(updatedRecord)
            @Expect(restored.source.token.isCancelled(), true)
            @Expect(runtime.beginHook(handler, parent.token).isNone(), true)
            runtime.endHook(restored)

            let current = runtime.beginHook(updatedHandler, parent.token).getOrThrow()
            runtime.revokePlugin(record)
            @Expect(current.source.token.isCancelled(), false)
            runtime.revokePlugin(updatedRecord)
            @Expect(current.source.token.isCancelled(), true)
            @Expect(runtime.beginHook(updatedHandler, parent.token).isNone(), true)
            runtime.endHook(current)
        } finally {
            parent.close()
            let _ = processes.close()
            remove(root, recursive: true)
        }
    }

    @TestCase
    func remotePluginAcquisitionCannotReadWorkspaceOrUseLocalDependencies(): Unit {
        let root = pluginContractTemp("remote-acquisition-isolation")
        let workspace = root + "/workspace"
        let packageRoot = root + "/stage/package"
        Directory.create(workspace + "/local-plugin", recursive: true)
        Directory.create(packageRoot, recursive: true)
        File.writeTo(packageRoot + "/package.json", (
            "{\"name\":\"remote-plugin\",\"version\":\"1.0.0\"," +
            "\"pi\":{\"skills\":[\"skills\"]},\"dependencies\":{" +
            "\"workspace-secret\":\"file:../../workspace/secret.tgz\"}}"
        ).toArray())
        try {
            let revision = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            let remoteSpec = match (productPluginSourceSpec(
                ProductPluginSourceRequest(
                    PluginSourceKind.Git,
                    "https://example.test/remote-plugin.git",
                    revision: revision
                ),
                ShellNetworkMode.Restricted
            )) {
                case PluginImportResult.Ok(value) => value
                case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
            }
            @Expect(remoteSpec.workspaceSource, false)
            @Expect(remoteSpec.revision, revision.toAsciiLower())
            @Expect(pluginAcquisitionCapabilities(
                remoteSpec.networkPolicy, workspace, remoteSpec.workspaceSource
            ).allows(CapabilityKind.WorkspaceRead, resource: workspace), false)
            @Expect(pluginAcquisitionAdditionalCapabilities(ToolCall(
                "remote-acquisition", "plugin_acquisition", objectValue([
                    ValueField("workspace_read_root", textValue(""))
                ])
            )).isEmpty(), true)
            @Expect(match (verifyAcquiredSource(root + "/stage", packageRoot, remoteSpec)) {
                case PluginImportResult.Err(error) =>
                    error.code == "plugin.acquisition_local_dependency_forbidden"
                case _ => false
            }, true)

            let localSpec = match (productPluginSourceSpec(
                ProductPluginSourceRequest(
                    PluginSourceKind.Git,
                    workspace + "/local-plugin",
                    revision: revision
                ),
                ShellNetworkMode.Restricted
            )) {
                case PluginImportResult.Ok(value) => value
                case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
            }
            @Expect(localSpec.revision, revision.toAsciiLower())
            @Expect(match (productPluginWorkspaceSourceAllowed(localSpec, workspace)) {
                case PluginImportResult.Ok(value) => value
                case _ => false
            }, true)
            @Expect(pluginAcquisitionCapabilities(
                localSpec.networkPolicy, workspace, localSpec.workspaceSource
            ).allows(CapabilityKind.WorkspaceRead, resource: workspace), true)
            let plannedWorkspaceRead = pluginAcquisitionAdditionalCapabilities(ToolCall(
                "local-acquisition", "plugin_acquisition", objectValue([
                    ValueField("workspace_read_root", textValue(workspace))
                ])
            ))
            @Expect(plannedWorkspaceRead.size, 1)
            @Expect(plannedWorkspaceRead[0].kind, CapabilityKind.WorkspaceRead)
            @Expect(plannedWorkspaceRead[0].resource, workspace)
        } finally {
            remove(root, recursive: true)
        }
    }
}

func pluginContractTemp(label: String): String {
    let base = homeDirectory() + "/.cache/agent-tmp/axyndra-issues-34-35-36"
    if (!exists(Path(base))) { Directory.create(base, recursive: true) }
    base + "/plugin-contract-" + label + "-" +
        DateTime.nowUTC().toUnixTimeStamp().toMilliseconds().toString()
}