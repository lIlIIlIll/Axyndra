package compaction_plugin

import pure_provider_runtime.*
import yjson_support.*

main(): Int64 {
    runDocumentPolicyProvider("compaction", "1.1.0", ["summarize"], checkpointToolDefinitions173(), [],
        { _, input => compactionPolicy(input) },
        { tool, input => checkpointToolPrepare173(tool, input) },
        { tool, input, _ => checkpointToolExecute173(tool, input) },
        { _, _ => throw IllegalArgumentException("compaction has no command contribution") })
}
