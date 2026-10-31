package agent_product

import agent_domain.*
import agent_host_runtime
import agent_host_runtime.*

type ProductHttpStreamLaunch = HostHttpStreamLaunch

func prepareHttpStreamLaunch(raw: AgentValue, credentials: Array<ProductPluginHttpCredentialValue>,
    policy: NetworkPolicy, payloadBody!: ?Array<Byte> = None, expanded!: Bool = false,
    timeoutMaximum!: Int64 = 120000, allowZeroTimeout!: Bool = false, modelEnvelope!: Bool = false): Result<ProductHttpStreamLaunch> {
    agent_host_runtime.prepareHostHttpStreamLaunch(raw, credentials, policy, payloadBody: payloadBody,
        expanded: expanded, timeoutMaximum: timeoutMaximum, allowZeroTimeout: allowZeroTimeout, modelEnvelope: modelEnvelope)
}
