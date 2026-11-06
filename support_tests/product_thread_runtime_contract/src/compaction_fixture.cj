package product_thread_runtime_contract

import agent_domain.*
import agent_product.*
import std.env.*
import std.fs.*
import yjson_support.*

// Actual public import, immutable package pin and operator configuration. This
// fixture has no execution authority and cannot manufacture a canonical Source.
func installProductCompactionContract96(product: ProductRuntime): Unit {
    let record = pluginAcquisitionRequireRecord(product.importLocalPlugin(
        getVariable("AXYNDRA_COMPACTION_PLUGIN_PACKAGE").getOrThrow(), PluginInstallScope.Workspace),
        "import independent Native Compaction package")
    let namespace = supportRegistryDescriptor96(record, "namespace")
    let digest = supportRegistryDescriptor96(record, "content_digest")
    expect(namespace == "axyndra:compaction", "actual Compaction package namespace")
    let directory = product.settingsRoot + "/plugins"
    if (!exists(Path(directory))) { Directory.create(directory, recursive: true) }
    // This Product starts with only the Program/Workspace service recipe. Do
    // not replace an existing policy or canonical grant recipe in this fixture.
    expect(!exists(Path(directory + "/policies.json")) && !exists(Path(directory + "/canonical-data.json")),
        "compaction fixture must not replace another operator policy")
    File.writeTo(directory + "/policies.json", stringifyUnifiedJson(objectValue([
        ValueField("version", integerValue(1)), ValueField("bindings", objectValue([
            ValueField("compaction", objectValue([ValueField("namespace", textValue(namespace)),
                ValueField("provider", textValue("summarize")), ValueField("package_digest", textValue(digest))]))]))])).toArray())
    let tools = ["checkpoint", "rewind"].map { name => objectValue([
        ValueField("name", textValue(name)), ValueField("provider", textValue("summarize")),
        ValueField("action", textValue("canonical.context.project")), ValueField("capability", textValue("workspace.read")),
        ValueField("effect", textValue("read_only"))]) }
    File.writeTo(directory + "/canonical-data.json", stringifyUnifiedJson(objectValue([
        ValueField("version", integerValue(1)), ValueField("plugins", listValue([objectValue([
            ValueField("namespace", textValue(namespace)), ValueField("package_digest", textValue(digest)),
            ValueField("tools", listValue(tools))])]))])).toArray())
    let _ = pluginAcquisitionRequireRecord(product.setPluginEnabled(namespace, true, PluginInstallScope.Workspace),
        "enable operator-pinned Native Compaction package")
}

func requireProductContract96<T>(result: Result<T>, stage: String): T {
    match (result) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(stage + ": " + error.code + ": " + error.message)
    }
}
