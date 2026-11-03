package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import yjson.*
import yjson_support.*

// An operator may select this small pure preparation dialect on the existing
// actual prepare_document Provider. It receives only the published local Tool
// name. Complete business parameters are transferred later under the actual
// paid input pin; this query never imposes a smaller business-input ceiling.
let MEMORY_LIVE_READ_PREPARATION_QUERY="axyndra.plugin-live-policy-read-query/v1"

func memoryLiveReadPreparation(value:AgentValue):AgentValue{
    memoryDocumentFields(value,["schema","tool"])
    if(memoryDocumentText(value,"schema")!=MEMORY_LIVE_READ_PREPARATION_QUERY ||
        !MEMORY_NATIVE_TOOLS.contains(memoryDocumentText(value,"tool"))){
        throw PureProviderError("memory.live_read_preparation_invalid","exact current Memory Tool preparation required")}
    // Logical policy selection only. The Host independently freezes current
    // operator rights, provider/package/generation and the real Tool binding.
    // Native receives no path, SQL, Thread, Source, grant or approval here.
    objectValue([ValueField("document_read",objectValue([ValueField("key",textValue(MEMORY_JOURNAL_KEY)),
        ValueField("kind",textValue("latest"))]))])
}
