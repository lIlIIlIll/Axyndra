package agent_host_runtime

import agent_domain.*
import process4cj as process

// Package-private physical data transfer. The sole original owner supplies
// actual current/Store/Derived proof before calling the adopted grant. Neither
// descriptor callbacks nor observed PID values are Sources or process grants.
interface HostManagedChannelNamespaceObservation {
    func captureManagedNamespaces(adopt:(process.ProcessSandboxNamespaces)->Unit):Result<Unit>
    func observedManagedPayload(owned:process.ProcessSandboxNamespaces,executable:String):Result<process.ProcessSandboxPayloadIdentity>
}
