package agent_product

import agent_host_runtime.*
import agent_store.*

class ProductContextManifestRuntime <: HostContextManifestRuntime {
    init(database: SqliteDatabase) {
        super(database, compilerVersion: "agent-product-context-v1", promptOwner: "agent-product-core")
    }
}
