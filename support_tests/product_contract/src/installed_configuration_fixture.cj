package product_contract

import agent_domain.*
import agent_product.*
import workspace_legacy_oracle.*
import std.collection.*
import std.env.*
import std.fs.*
import yjson.*
import yjson_support.*

// The legacy catalog still supplies explicit pricing and display preferences.
// Execution capabilities now come from a versioned operator mapping to a real
// installed package. This fixture grants neither HTTP nor credential access.
func configurationContractModelMapping(model: String, output: Int64, enhanced: Bool): AgentValue {
    let levels: Array<AgentValue> = if (enhanced) {
        [textValue("minimal"), textValue("low"), textValue("medium"), textValue("high"), textValue("xhigh"), textValue("max")]
    } else { [] }
    let capabilities = objectValue([
        ValueField("context_window", integerValue(200000)), ValueField("max_output", integerValue(output)),
        ValueField("endpoint_max_output", nullValue()),
        ValueField("thinking", objectValue([ValueField("mode", textValue(if (enhanced) { "effort" } else { "none" })),
            ValueField("levels", listValue(levels)), ValueField("tiers", listValue([]))])),
        ValueField("tools", boolValue(true)), ValueField("parallel_tools", boolValue(true)),
        ValueField("images", boolValue(enhanced)), ValueField("structured_output", boolValue(enhanced)),
        ValueField("prompt_cache", boolValue(enhanced))])
    objectValue([ValueField("version", integerValue(2)), ValueField("capabilities", capabilities),
        ValueField("model", textValue("local-openai/" + model)),
        ValueField("contribution", textValue("openai-chat-completions")), ValueField("wire_model", textValue(model)),
        ValueField("provider_id", textValue("local-openai")), ValueField("credential_refs", listValue([])),
        ValueField("configuration", objectValue([ValueField("base_url", textValue("http://127.0.0.1:11434")),
            ValueField("provider", textValue("custom")), ValueField("dialect", textValue("generic_chat")),
            ValueField("headers", objectValue([])), ValueField("timeout_ms", integerValue(9000)),
            ValueField("allow_insecure_http", boolValue(true))]))])
}

func configurationContractInstall(product: ProductRuntime, variable: String): ProductPluginRecord {
    let record = match (product.importLocalPlugin(getVariable(variable).getOrThrow())) {
        case PluginRegistryResult.Ok(value) => supportRegistryRecord96(value)
        case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code + ": " + supportRegistryExclusiveErrorText96(error))
    }
    expect(supportRegistryOkay96(product.setPluginEnabled(supportRegistryDescriptor96(record,"namespace"), true)),
        "configuration contract enables its installed package")
    record
}

func installConfigurationContractPlugins(product: ProductRuntime, settingsRoot: String): ProductPluginRecord {
    let model = configurationContractInstall(product, "AXYNDRA_MODEL_PROVIDER_PLUGIN_PACKAGE")
    let compaction = configurationContractInstall(product, "AXYNDRA_COMPACTION_PLUGIN_PACKAGE")
    let directory = settingsRoot + "/plugins"
    if (!exists(Path(directory))) { Directory.create(directory, recursive: true) }
    // This settings directory is created by prepareContractFiles, independently
    // of other contracts. Do not silently overwrite unexpected service grants.
    expect(!exists(Path(directory + "/services.json")), "configuration fixture owns its fresh service document")
    File.writeTo(directory + "/services.json", stringifyUnifiedJson(objectValue([
        ValueField("version", integerValue(1)), ValueField("plugins", listValue([objectValue([
            ValueField("namespace", textValue(supportRegistryDescriptor96(model,"namespace"))),
            ValueField("package_digest", textValue(supportRegistryDescriptor96(model,"content_digest"))),
            ValueField("configuration", objectValue([ValueField("model_providers", listValue([
                configurationContractModelMapping("local-model", 8192, true),
                configurationContractModelMapping("backup-model", 16384, false)]))])),
            ValueField("requests", listValue([])), ValueField("credentials", listValue([]))])]))])).toArray())
    let bindings = ArrayList<ValueField>()
    let policyPath = directory + "/policies.json"
    if (exists(Path(policyPath))) {
        let existing = parseUnifiedJson(String.fromUtf8(File.readFrom(policyPath)))
        for (field in existing.field("bindings").getOrThrow().fields where field.name != "compaction") { bindings.add(field) }
    }
    bindings.add(ValueField("compaction", objectValue([
        ValueField("namespace", textValue(supportRegistryDescriptor96(compaction,"namespace"))), ValueField("provider", textValue("summarize")),
        ValueField("package_digest", textValue(supportRegistryDescriptor96(compaction,"content_digest")))])))
    File.writeTo(policyPath, stringifyUnifiedJson(objectValue([
        ValueField("version", integerValue(1)), ValueField("bindings", objectValue(bindings.toArray()))])).toArray())
    compaction
}

// This independent profile directory needs its own installed operator mapping.
// Keep catalog/profile round-trip and original cache assertions unchanged; the
// production request path reads typed plugin capabilities, not provider names.
func configurationContractProfileModelMapping(official: Bool): AgentValue {
    let profile = if (official) { "anthropic-official" } else { "deepseek-anthropic" }
    let levels: Array<String> = ["minimal", "low", "medium", "high", "xhigh", "max"]
    let budgets: Array<Int64> = [1024, 2048, 8192, 16384, 32768, 32768]
    let tiers = ArrayList<AgentValue>()
    for (index in 0..levels.size) {
        tiers.add(objectValue([ValueField("level", textValue(levels[index])), ValueField("tokens", integerValue(budgets[index]))]))
    }
    let capabilities = objectValue([
        ValueField("context_window", integerValue(128000)), ValueField("max_output", integerValue(16384)),
        ValueField("endpoint_max_output", nullValue()),
        ValueField("thinking", objectValue([ValueField("mode", textValue("budget")),
            ValueField("levels", listValue(levels.map { level => textValue(level) })), ValueField("tiers", listValue(tiers.toArray()))])),
        ValueField("tools", boolValue(true)), ValueField("parallel_tools", boolValue(official)),
        ValueField("images", boolValue(false)), ValueField("structured_output", boolValue(false)),
        ValueField("prompt_cache", boolValue(official))])
    objectValue([ValueField("version", integerValue(2)), ValueField("capabilities", capabilities),
        ValueField("model", textValue(profile + "/shared-model")), ValueField("contribution", textValue("anthropic-messages")),
        ValueField("wire_model", textValue("shared-model")), ValueField("provider_id", textValue(profile)),
        ValueField("credential_refs", listValue([])),
        ValueField("configuration", objectValue([
            ValueField("base_url", textValue(if (official) { "https://api.anthropic.com" } else { "https://api.deepseek.com/anthropic" })),
            ValueField("provider", textValue("anthropic")),
            ValueField("dialect", textValue(if (official) { "anthropic_messages" } else { "deepseek_messages" })),
            ValueField("headers", objectValue([])), ValueField("timeout_ms", integerValue(10000)),
            ValueField("allow_insecure_http", boolValue(false))]))])
}

func installProfileConfigurationContractModel(product: ProductRuntime, settingsRoot: String): Unit {
    let model = configurationContractInstall(product, "AXYNDRA_MODEL_PROVIDER_PLUGIN_PACKAGE")
    let directory = settingsRoot + "/plugins"
    if (!exists(Path(directory))) { Directory.create(directory, recursive: true) }
    expect(!exists(Path(directory + "/services.json")), "profile fixture owns its fresh service document")
    File.writeTo(directory + "/services.json", stringifyUnifiedJson(objectValue([
        ValueField("version", integerValue(1)), ValueField("plugins", listValue([objectValue([
            ValueField("namespace", textValue(supportRegistryDescriptor96(model,"namespace"))),
            ValueField("package_digest", textValue(supportRegistryDescriptor96(model,"content_digest"))),
            ValueField("configuration", objectValue([ValueField("model_providers", listValue([
                configurationContractProfileModelMapping(true), configurationContractProfileModelMapping(false)]))])),
            ValueField("requests", listValue([])), ValueField("credentials", listValue([]))])]))])).toArray())
}

// The configuration fixture already imported this exact package and selected it.
// Verify the original imported identity and active record, never swallow a
// duplicate import or replace an unexpected package/selection.
func requireConfigurationContractCompaction(product: ProductRuntime, expected: ProductPluginRecord): Unit {
    var matches: Int64 = 0
    // The public snapshot list is index-addressed, not an iterator; walk it
    // explicitly and keep the same namespace filter.
    let snapshots = product.pluginSnapshots()
    for (index in 0..snapshots.size) {
        let current = snapshots.at(index)
        if (supportRegistryDescriptor96(current,"namespace") != supportRegistryDescriptor96(expected,"namespace")) { continue }
        expect(supportRegistryDescriptor96(current,"root") == supportRegistryDescriptor96(expected,"root") &&
            supportRegistryDescriptor96(current,"id") == supportRegistryDescriptor96(expected,"id") && supportRegistryDescriptor96(current,"version") == supportRegistryDescriptor96(expected,"version") &&
            supportRegistryDescriptor96(current,"content_digest") == supportRegistryDescriptor96(expected,"content_digest") && supportRegistryField96(current,"content_digest") == supportRegistryField96(expected,"content_digest") &&
            supportRegistryField96(current,"locator") == supportRegistryField96(expected,"locator") && supportRegistryField96(current,"locator") == getVariable("AXYNDRA_COMPACTION_PLUGIN_PACKAGE").getOrThrow() &&
            supportRegistryData96(current).enabled && !supportRegistryData96(current).explicitlyDisabled &&
            (match (supportRegistryData96(current).sourceKind) { case PluginSourceKind.Local => true; case _ => false }) &&
            (match (supportRegistryData96(current).scope) { case PluginInstallScope.User => true; case _ => false }),
            "configuration fixture reuses only its original enabled local Compaction package")
        matches += 1
    }
    expect(matches == 1, "configuration fixture retains exactly one original Compaction record")
    let settings = parseUnifiedJson(String.fromUtf8(File.readFrom(product.settingsRoot + "/plugins/policies.json")))
    let actual = settings.field("bindings").getOrThrow().field("compaction").getOrThrow()
    expect(canonicalAgentValue(actual) == canonicalAgentValue(objectValue([
        ValueField("namespace", textValue(supportRegistryDescriptor96(expected,"namespace"))), ValueField("provider", textValue("summarize")),
        ValueField("package_digest", textValue(supportRegistryDescriptor96(expected,"content_digest")))])),
        "configuration fixture preserves the explicit installed Compaction selection")
}
