package agent_product

import agent_plugin_registry

import tool_runtime.*
import std.convert.*

import agent_domain.*
import agent_extension_runtime.*
import agent_store.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class CodingDistributionFixture {
    let root = pluginContractTemp("coding-distribution")
    let bundle: String
    let digest: String
    init() {
        // The shipped recipe binds ${settings_root}/... sources and the initial
        // context parser canonicalizes that root, so the fixture must create the
        // settings root it hands to openProduct, like the other fixtures do.
        if (!exists(Path(root + "/settings"))) { Directory.create(root + "/settings", recursive: true) }
        let target = root + "/installed/share/axyndra"
        Directory.create(target + "/plugins/skills", recursive: true)
        pluginCopySnapshotTreeSecure(getVariable("AXYNDRA_SKILLS_PLUGIN_PACKAGE").getOrThrow(), target + "/plugins/skills")
        let descriptor = match (inspectPluginPackage(target + "/plugins/skills")) {
            case PluginPackageResult.Ok(value) => value
            case PluginPackageResult.Err(error) => throw IllegalStateException(error.code) }
        Directory.create(target + "/profiles")
        // Actual shipped recipe, not a test-only reimplementation of defaults.
        let recipe = String.fromUtf8(File.readFrom("profiles/coding-context.json"))
        File.writeTo(target + "/profiles/coding-context.json", recipe.toArray())
        File.writeTo(target + "/distribution.json", stringifyUnifiedJson(objectValue([
            ValueField("schema", textValue("axyndra.distribution/v1")), ValueField("id", textValue("coding")),
            ValueField("plugins", listValue([objectValue([ValueField("path", textValue("plugins/skills")),
                ValueField("namespace", textValue(descriptor.namespace)), ValueField("version", textValue(descriptor.version)),
                ValueField("package_digest", textValue(descriptor.contentDigest)), ValueField("enabled", boolValue(true))])])),
            ValueField("context", objectValue([ValueField("namespace", textValue(descriptor.namespace)),
                ValueField("recipe", textValue("profiles/coding-context.json")), ValueField("sha256", textValue(modelPolicySha256Text(recipe)))]))])).toArray())
        this.bundle = target; this.digest = descriptor.contentDigest
    }
    func open(workspace: String, approval!: ApprovalMode = ApprovalMode.Yolo, bundled!: Bool = true): Result<ProductRuntime> {
        openProduct(config: ProductConfig(workspaceRoot: workspace, settingsRoot: root + "/settings",
            stateRoot: root + "/state", fixture: true, approvalMode: approval,
            distributionRoot: if (bundled) { bundle } else { "" }))
    }
    func close(): Unit { remove(root, recursive: true) }
}

@Test
class CodingDistributionTests {
    @TestCase
    func realOpenInstallsEnablesAndUsesCanonicalInitialReadsBeforeModel(): Unit {
        let f = CodingDistributionFixture()
        try {
            writeObservedSkill(f.root + "/workspace/.omp/skills", "DEFAULT-CODING-WORKSPACE")
            let product = lifecycleTestRequire(f.open(f.root + "/workspace"))
            try {
                @Expect(productRegistryRecords83(product.pluginSnapshots()).size, 1)
                let record = productRegistryRecords83(product.pluginSnapshots())[0]
                @Expect(record.enabled); @Expect(productRegistryCopyText83(record.copyText(PluginRecordText.ContentLock)), f.digest)
                let database = SqliteDatabase(f.root + "/state/state.db")
                try {
                    @Expect(database.scalarInt("SELECT COUNT(*) FROM runs"), 0)
                    @Expect(database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
                    let app = product.applicationSession()
                    @Expect(app.submit("$review").isOk())
                    @Expect(product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system.contains("DEFAULT-CODING-WORKSPACE"))
                    @Expect(database.scalarInt("SELECT COUNT(DISTINCT run_id) FROM operations"), 1)
                    @Expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'"), 1)
                    @Expect(Int64.parse(database.query("SELECT COUNT(*) FROM operation_effect_records e JOIN operation_receipts r ON r.operation_id=e.operation_id WHERE e.tool_id=? AND r.outcome='completed'",
                        [SqlParameter.Text(HOST_CONTEXT_READ_TOOL)])[0].required(0)) >= 2)
                    @Expect(database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing','waiting_approval')"), 0)
                    let before = String.fromUtf8(File.readFrom(f.root + "/settings/plugins/context.json"))
                    @Expect(applyProductDistributionDefaults(product, f.bundle).isOk())
                    @Expect(productRegistryRecords83(product.pluginSnapshots()).size, 1)
                    @Expect(String.fromUtf8(File.readFrom(f.root + "/settings/plugins/context.json")), before)
                } finally { database.close() }
            } finally { product.close() }
        } finally { f.close() }
    }

    @TestCase
    func realAlwaysAskRejectsDefaultReadWithoutModelOrGrantedShortcut(): Unit {
        let f = CodingDistributionFixture()
        try {
            writeObservedSkill(f.root + "/workspace/.omp/skills", "APPROVAL-ONLY-BODY")
            let product = lifecycleTestRequire(f.open(f.root + "/workspace", approval: ApprovalMode.AlwaysAsk))
            try {
                let app = product.applicationSession()
                let approval = lifecycleTestRequire(app.submit("$review")).approval.getOrThrow()
                @Expect(approval.toolName, HOST_CONTEXT_READ_TOOL)
                @Expect(product.fixtureProbe.getOrThrow().lastRequest.isNone())
                let database = SqliteDatabase(f.root + "/state/state.db")
                try {
                    @Expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 0)
                    let _ = app.decide(approval.operationId.value, ApprovalDecision.Reject)
                    @Expect(product.fixtureProbe.getOrThrow().lastRequest.isNone())
                    @Expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'"), 0)
                    @Expect(database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing','waiting_approval')"), 0)
                } finally { database.close() }
            } finally { product.close() }
        } finally { f.close() }
    }

    @TestCase
    func sameSettingsRebindsWorkspaceTemplateWithoutRewritingOperatorFile(): Unit {
        let f = CodingDistributionFixture()
        try {
            writeObservedSkill(f.root + "/first/.omp/skills", "FIRST-WORKSPACE-CONTEXT")
            writeObservedSkill(f.root + "/second/.omp/skills", "SECOND-WORKSPACE-CONTEXT")
            let first = lifecycleTestRequire(f.open(f.root + "/first"))
            try {
                @Expect(first.applicationSession().submit("$review").isOk())
                @Expect(first.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system.contains("FIRST-WORKSPACE-CONTEXT"))
            } finally { first.close() }
            let path = f.root + "/settings/plugins/context.json"
            let encoded = String.fromUtf8(File.readFrom(path))
            @Expect(encoded.contains("$" + "{workspace_root}"))
            let second = lifecycleTestRequire(f.open(f.root + "/second"))
            try {
                @Expect(second.applicationSession().submit("$review").isOk())
                let system = second.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system
                @Expect(system.contains("SECOND-WORKSPACE-CONTEXT")); @Expect(!system.contains("FIRST-WORKSPACE-CONTEXT"))
                @Expect(String.fromUtf8(File.readFrom(path)), encoded)
            } finally { second.close() }
        } finally { f.close() }
    }

    @TestCase
    func existingDisableAndExplicitConfigurationArePreservedWithoutLegacyFallback(): Unit {
        let f = CodingDistributionFixture()
        try {
            writeObservedSkill(f.root + "/workspace/.omp/skills", "MUST-NOT-FALL-BACK")
            let product = lifecycleTestRequire(f.open(f.root + "/workspace"))
            try {
                let record = productRegistryRecords83(product.pluginSnapshots())[0]
                @Expect(product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), false).isOk())
                let path = f.root + "/settings/plugins/context.json"
                let previous = String.fromUtf8(File.readFrom(path))
                @Expect(applyProductDistributionDefaults(product, f.bundle).isOk())
                @Expect(!productRegistryRecords83(product.pluginSnapshots())[0].enabled)
                @Expect(String.fromUtf8(File.readFrom(path)), previous)
                let _ = product.applicationSession().submit("$review")
                @Expect(product.fixtureProbe.getOrThrow().lastRequest.isNone())
                File.writeTo(path, "{\"operator-selection\":true}".toArray())
                @Expect(applyProductDistributionDefaults(product, f.bundle).isOk())
                @Expect(String.fromUtf8(File.readFrom(path)), "{\"operator-selection\":true}")
            } finally { product.close() }
        } finally { f.close() }
    }

    @TestCase
    func freshConfigurationPreservesDisabledUserProviderAndKeepsManagementUsable(): Unit {
        for (version in ["1.0.0", "7.1.0"]) {
            let f = CodingDistributionFixture()
            try {
                writeObservedSkill(f.root + "/workspace/.omp/skills", "EXPLICIT-ENABLE-ONLY")
                let source = f.root + "/user-provider"
                Directory.create(source)
                pluginCopySnapshotTreeSecure(f.bundle + "/plugins/skills", source)
                let manifestPath = source + "/axyndra.plugin.json"
                let manifest = parseUnifiedJson(String.fromUtf8(File.readFrom(manifestPath)))
                manifest.put("version", textValue(version))
                File.writeTo(manifestPath, stringifyUnifiedJson(manifest).toArray())
                let initial = lifecycleTestRequire(f.open(f.root + "/workspace", bundled: false))
                try {
                    @Expect(initial.importLocalPlugin(source, PluginInstallScope.User).isOk())
                    @Expect(!productRegistryRecords83(initial.pluginSnapshots())[0].enabled)
                    @Expect(!exists(Path(f.root + "/settings/plugins/context.json")))
                } finally { initial.close() }
                let product = lifecycleTestRequire(f.open(f.root + "/workspace"))
                try {
                    let record = productRegistryRecords83(product.pluginSnapshots())[0]
                    @Expect(!record.enabled); @Expect(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Version)), version)
                    let path = f.root + "/settings/plugins/context.json"
                    let selected = parseUnifiedJson(String.fromUtf8(File.readFrom(path)))
                    @Expect(httpIntentText(selected, "package_digest"), productRegistryCopyText83(record.copyText(PluginRecordText.ContentLock)))
                    let result = product.applicationSession().submit("$review")
                    @Expect(result.isError()); @Expect(result.error().getOrThrow().code, "context.provider_missing")
                    @Expect(product.fixtureProbe.getOrThrow().lastRequest.isNone())
                    let database = SqliteDatabase(f.root + "/state/state.db")
                    try {
                        @Expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
                        @Expect(database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
                    } finally { database.close() }
                    // The matching native build can be explicitly enabled
                    // through the same still-usable management API.
                    if (version == "1.0.0") {
                        @Expect(product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), true).isOk())
                        @Expect(product.applicationSession().submit("$review").isOk())
                        @Expect(product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system.contains("EXPLICIT-ENABLE-ONLY"))
                    }
                } finally { product.close() }
            } finally { f.close() }
        }
    }

    @TestCase
    func independentCompatibleUserPackageIsSelectedWithoutBundleDigestEquality(): Unit {
        let f = CodingDistributionFixture()
        try {
            writeObservedSkill(f.root + "/workspace/.omp/skills", "USER-PACKAGE-CONTEXT")
            let source = f.root + "/updated-provider"
            Directory.create(source)
            pluginCopySnapshotTreeSecure(f.bundle + "/plugins/skills", source)
            File.writeTo(source + "/operator-release.txt", "Independent compatible package contents".toArray())
            let initial = lifecycleTestRequire(f.open(f.root + "/workspace", bundled: false))
            try {
                let record = match (initial.importLocalPlugin(source, PluginInstallScope.User)) {
                    case PluginRegistryResult.Ok(value) => value
                    case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code) }
                @Expect(productRegistryCopyText83(record.copyText(PluginRecordText.ContentLock)) != f.digest)
                @Expect(initial.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), true).isOk())
            } finally { initial.close() }
            let product = lifecycleTestRequire(f.open(f.root + "/workspace"))
            try {
                @Expect(productRegistryRecords83(product.pluginSnapshots()).size, 1)
                let record = productRegistryRecords83(product.pluginSnapshots())[0]
                @Expect(record.enabled); @Expect(productRegistryCopyText83(record.copyText(PluginRecordText.ContentLock)) != f.digest)
                let selected = parseUnifiedJson(String.fromUtf8(File.readFrom(f.root + "/settings/plugins/context.json")))
                @Expect(httpIntentText(selected, "package_digest"), productRegistryCopyText83(record.copyText(PluginRecordText.ContentLock)))
                @Expect(product.applicationSession().submit("$review").isOk())
                @Expect(product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system.contains("USER-PACKAGE-CONTEXT"))
                let database = SqliteDatabase(f.root + "/state/state.db")
                try {
                    @Expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'"), 1)
                    @Expect(database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing','waiting_approval')"), 0)
                } finally { database.close() }
            } finally { product.close() }
        } finally { f.close() }
    }

    @TestCase
    func invalidBundleAndTemplateRejectBeforeAnyImportOrModel(): Unit {
        let f = CodingDistributionFixture()
        try {
            Directory.create(f.root + "/workspace")
            let product = lifecycleTestRequire(f.open(f.root + "/workspace", bundled: false))
            try {
                @Expect(productRegistryRecords83(product.pluginSnapshots()).size, 0)
                @Expect(!exists(Path(f.root + "/settings/plugins/context.json")))
                let manifestPath = f.bundle + "/distribution.json"
                let original = String.fromUtf8(File.readFrom(manifestPath))
                for (wrong in ["../plugins/skills", "/tmp/skills", "plugins/../skills"]) {
                    let manifest = parseUnifiedJson(original)
                    manifest.field("plugins").getOrThrow().items[0].put("path", textValue(wrong))
                    File.writeTo(manifestPath, stringifyUnifiedJson(manifest).toArray())
                    @Expect(applyProductDistributionDefaults(product, f.bundle).isError())
                    @Expect(productRegistryRecords83(product.pluginSnapshots()).size, 0)
                }
                File.writeTo(manifestPath, original.toArray())
                let recipePath = f.bundle + "/profiles/coding-context.json"
                File.writeTo(recipePath, (String.fromUtf8(File.readFrom(recipePath)) + " ").toArray())
                @Expect(applyProductDistributionDefaults(product, f.bundle).isError())
                @Expect(productRegistryRecords83(product.pluginSnapshots()).size, 0)
                for (source in ["$" + "{HOME}/skills", "$workspace_root/skills", "$" + "{workspace_root}/../outside", "$" + "{workspace_root}/$" + "{ENV}/skills"]) {
                    let value = objectValue([ValueField("resources", listValue([objectValue([ValueField("source", textValue(source))])]))])
                    @Expect(bindInitialContextRootTemplates(value, f.root, f.root).isError())
                }
                @Expect(product.fixtureProbe.getOrThrow().lastRequest.isNone())
            } finally { product.close() }
        } finally { f.close() }
    }
}
