package agent_host_runtime

import agent_domain.*
import tool_runtime.*

// Physical resource custody only. Constructor is package-private and its
// actual factory first adopts the Session into the existing Host collector.
// It cannot mint Source, approve a child, settle a Receipt or retry effects.
public class HostLiveExecutionCustody <: LiveToolExecutionCustody {
    private let owner:HostDocumentDataSession
    init(owner:HostDocumentDataSession){this.owner=owner}
    // Host-package data identity only. The original single-use Session
    // retains executionPending before this physical custody can be issued.
    func matchesSession332(actual:HostDocumentDataSession):Bool{refEq(owner,actual)}
    public func releaseTransient():Result<Unit>{owner.releaseExecutionTransient()}
    public func close():Result<Unit>{owner.closeExecutionCustody()}
}
