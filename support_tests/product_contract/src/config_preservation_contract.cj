package product_contract

import agent_product.*
import agent_domain.*
import std.fs.*

func runConfigPreservationContract(root: String): Unit {
    let settings = root + "/settings"
    Directory.create(settings, recursive: true)
    let preserved = "# retain comment\nasync:\n  enabled: false\napproval:\n  mode: never\n" +
        "compaction:\n  enabled: false\nmodel_roles:\n  approval: old/reviewer\nfuture_setting: keep-me\n"
    let path = settings + "/config.yml"
    File.writeTo(path, ("default_model: old/model\ntheme: dark\n" + preserved).toArray())
    let originalProfile = ProviderProfile("old", "openai", "responses", "https://api.openai.com",
        "CONFIG_CONTRACT_UNSET_KEY", dialect: "openai_responses")
    upsertProviderProfile(settings, originalProfile).value().getOrThrow()
    upsertModelCatalogEntry(settings, ModelCatalogEntry("model", providerProfile: "old")).value().getOrThrow()
    upsertModelCatalogEntry(settings, ModelCatalogEntry("reviewer", providerProfile: "old")).value().getOrThrow()
    let product = openProduct(config: ProductConfig(settingsRoot: settings,
        stateRoot: root + "/state", workspaceRoot: root, startupMode: ProductStartupMode.LocalMaintenance)).value().getOrThrow()
    try {
        expect(product.saveTheme("light").isOk(), "theme mutation succeeds")
        let themed = String.fromUtf8(File.readFrom(path))
        expect(themed.contains(preserved) && themed.contains("default_model: old/model") &&
            loadProductSettings(settings).value().getOrThrow().theme == "light",
            "theme mutation preserves role, unknown key, comment and unrelated settings")
        let profile = ProviderProfile("configured", "openai", "responses", "https://api.openai.com",
            "CONFIG_CONTRACT_UNSET_KEY", dialect: "openai_responses")
        expect(product.configureProvider(profile, "gpt-5").isOk(), "provider mutation succeeds")
        let configured = String.fromUtf8(File.readFrom(path))
        expect(configured.contains(preserved) && configured.contains("configured/gpt-5") &&
            loadProductSettings(settings).value().getOrThrow().theme == "light",
            "provider mutation preserves role, unknown key, comment and updated theme")
        let before = configured
        let invalid = ProviderProfile("invalid", "openai", "responses", "https://api.openai.com",
            "CONFIG_CONTRACT_UNSET_KEY")
        expect(!product.configureProvider(invalid, "gpt-5").isOk() &&
            String.fromUtf8(File.readFrom(path)) == before,
            "invalid provider leaves default configuration unchanged")
    } finally { let _ = product.close() }
}
