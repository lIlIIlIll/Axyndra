package agent_product

import agent_domain.*
import agent_plugin_registry
import agent_store.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Real Product/Registry/Native mount and real SQLite observation. No test
// constructs a Root, prepared plan, Receipt, canonical Item or cut witness.
@Test
class InstalledCanonicalCheckpoint173Tests {
    @TestCase
    func ActualDefaultCatalogHasMountedNativeNamesAndNoBareBusinessFallback(): Unit {
        let f = CompactionPolicyFixture(seedDefaultHistory: false)
        try {
            var checkpoint = false; var rewind = false
            for (tool in f.product.tools()) {
                @Expect(tool.name != "checkpoint"); @Expect(tool.name != "rewind")
                if (tool.name == "plugin.axyndra:compaction.checkpoint") { checkpoint = true }
                if (tool.name == "plugin.axyndra:compaction.rewind") { rewind = true }
            }
            @Expect(checkpoint); @Expect(rewind)
            let operations = f.database.scalarInt("SELECT COUNT(*) FROM operations")
            @Expect(f.product.invokeLocalTool(f.session, "checkpoint", objectValue([ValueField("goal", textValue("no alias"))])).isError())
            @Expect(f.product.invokeLocalTool(f.session, "rewind", objectValue([ValueField("report", textValue("no alias"))])).isError())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), operations)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM context_checkpoints"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
        } finally { f.close() }
    }
    @TestCase
    func MissingOperatorFileAndCallerBindingCannotExecuteOrGrantCanonicalSource(): Unit {
        let f = CompactionPolicyFixture(seedDefaultHistory: false)
        try {
            remove(f.root + "/settings/plugins/canonical-data.json")
            let operations = f.database.scalarInt("SELECT COUNT(*) FROM operations")
            let actual = f.product.invokeLocalTool(f.session, "plugin.axyndra:compaction.checkpoint", objectValue([
                ValueField("goal", textValue("work")), ValueField("projection_binding", objectValue([
                    ValueField("action", textValue("canonical.context.project")), ValueField("capability", textValue("workspace.read")),
                    ValueField("effect", textValue("read_only"))]))]))
            @Expect(actual.isError())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), operations)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM context_checkpoints"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
        } finally { f.close() }
    }
    @TestCase
    func DisabledActualPackageWithdrawsNativeNamesWithoutLegacyFallback(): Unit {
        let f = CompactionPolicyFixture(seedDefaultHistory: false)
        try {
            let namespace = productRegistryCopyText83(f.record.getOrThrow().descriptor.copyText(PluginDescriptorText.Namespace))
            @Expect(f.product.setPluginEnabled(namespace, false).isOk())
            for (tool in f.product.tools()) {
                @Expect(tool.name != "checkpoint"); @Expect(tool.name != "rewind")
                @Expect(tool.name != "plugin.axyndra:compaction.checkpoint"); @Expect(tool.name != "plugin.axyndra:compaction.rewind")
            }
            let operations = f.database.scalarInt("SELECT COUNT(*) FROM operations")
            @Expect(f.product.invokeLocalTool(f.session, "plugin.axyndra:compaction.checkpoint",
                objectValue([ValueField("goal", textValue("disabled"))])).isError())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), operations)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM context_checkpoints"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
        } finally { f.close() }
    }
}
