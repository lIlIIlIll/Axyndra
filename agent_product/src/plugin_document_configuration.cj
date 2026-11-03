package agent_product

import agent_host_runtime.*
import agent_domain.*
import yjson_support.*

type ProductPluginDocumentConfiguration = HostPluginDocumentConfiguration

func productDocumentLogicalName(value: String): Bool {
    hostDocumentLogicalName(value)
}

func loadProductPluginDocumentConfiguration(settingsRoot: String, namespace: String,
    packageDigest: String): Result<ProductPluginDocumentConfiguration> {
    loadHostPluginDocumentConfiguration(settingsRoot, namespace, packageDigest)
}

func productDocumentToolConfigurationValid(tool: AgentValue): Bool {
    hostDocumentToolConfigurationValid(tool)
}
