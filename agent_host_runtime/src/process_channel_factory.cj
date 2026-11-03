package agent_host_runtime

import agent_domain.*
import agent_ports.*
import std.sync.*

// LocalProcessPort owns this entry before gateway acquisition or process
// launch. A failed or pending close cannot recycle the operation identity or
// the <=32 channel reservation while any owned resource remains alive.
class HostNativeProcessChannelOwner {
    let resourceOwner: ProcessResourceOwner
    let cancellation: CancellationSource
    var opening = true
    var processStarted = false
    var cancelled = false
    var released = false
    var channel: ?ProcessChannel = None
    var gateway: ?NetworkGatewayLease = None
    let releaseLock = Mutex()
    let cleanupLock = Mutex()
    var cleanupStarted = false
    let cleanupDone = AtomicBool(false)
    let cleanupFailed = AtomicBool(false)
    var cleanup: ?Future<Unit> = None

    init(resourceOwner: ProcessResourceOwner, parent: CancellationToken) {
        this.resourceOwner = resourceOwner
        this.cancellation = CancellationSource(parent: Some(parent))
    }
}

public func hostNativeChannelFactoryError(kind: AgentErrorKind, code: String, message: String): AgentError {
    AgentError(kind, code, message, retryable: false, fallbackAllowed: false)
}
