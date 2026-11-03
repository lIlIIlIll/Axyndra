package agent_host_runtime

import agent_domain.*
import yjson.*
import yjson_support.*

// Neutral publication state; prepaid by the actual admission before creation.
// The existing Core/Direct queue owns the exact consumer after acceptance.
class HostHubProcessFailurePublication180 {
    var classified=false
    var kind=AgentErrorKind.RecoveryRequired
    var recoverable=false
    var output:?AgentValue=None<AgentValue>
    var marker:?AgentError=None<AgentError>
    init(){}
}

