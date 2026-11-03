package agent_product

import agent_domain.*
import agent_host_runtime

class ApplicationPluginServiceStartup {
    let target: SessionId
    let namespace: String
    let serviceId: String
    let cancellation = CancellationSource()
    init(target: SessionId, namespace: String, serviceId: String) {
        this.target = target; this.namespace = namespace; this.serviceId = serviceId
    }
}

// The canonical Run token remains a parent. A host caller can cancel only its
// startup window; close detaches that caller and leaves the lease's independent
// lifecycle source intact. No plugin data can construct this link.
type ProductServiceCallerCancellation = agent_host_runtime.HostCallerCancellation

func pluginServiceStartupCancelled<T>(): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Cancelled, "plugin.service_start_cancelled",
        "service startup was cancelled before publication completed"))
}
