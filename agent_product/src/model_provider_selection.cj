package agent_product

import agent_domain.*
import agent_runtime.*
import agent_store.*
import agent_host_runtime
import agent_host_runtime.*
import std.collection.*
import yjson.*

// Legacy authentication metadata cannot select a provider or supply secrets.
class ProductLegacyModelDiagnostic <: HostModelMigrationDiagnostic {
    private let unsupportedLegacyAuthentication: HashMap<String, String>
    init(catalog: Array<ModelCatalogEntry>, profiles: Array<ProviderProfile>) {
        let unsupported = HashMap<String, String>()
        for (entry in catalog) {
            for (profile in profiles where profile.id == entry.providerProfile && profile.authentication == "oauth") {
                unsupported[entry.displayId()] = profile.id
            }
        }
        this.unsupportedLegacyAuthentication = unsupported
    }
    public func diagnose(model: String): ?AgentError {
        match (unsupportedLegacyAuthentication.get(model)) {
            case Some(provider) => Some(AgentError(AgentErrorKind.Configuration, "oauth_not_supported",
                "OAuth authentication is not implemented in Phase 1", fields: [ErrorField("provider", provider)]))
            case None => None
        }
    }
}
class ProductInstalledModelPort <: HostInstalledModelPort {
    init(host: ProductJavaScriptPluginHost, settingsRoot: String, database: SqliteDatabase,
        runtimes: ThreadRuntimeRegistry, processes: LocalProcessPort, catalog: Array<ModelCatalogEntry>,
        profiles: Array<ProviderProfile>, artifacts: ProductArtifactStore) {
        super(host, settingsRoot, database, runtimes, processes, artifacts,
            migrationDiagnostic: Some(productLegacyModelDiagnostic(catalog, profiles)))
    }
}
func productLegacyModelDiagnostic(catalog: Array<ModelCatalogEntry>, profiles: Array<ProviderProfile>): HostModelMigrationDiagnostic {
    let diagnostic: HostModelMigrationDiagnostic = ProductLegacyModelDiagnostic(catalog, profiles)
    diagnostic
}
func installedModelSnapshotSchema(value: AgentValue): Bool { agent_host_runtime.installedModelSnapshotSchema(value) }
