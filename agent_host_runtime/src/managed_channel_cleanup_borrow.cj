package agent_host_runtime

import agent_domain.*
import std.sync.*

// Trusted Host composition can observe custody, but cannot obtain a grant,
// Source/Prepared/Root, descriptor, PID, ACK/close or effect entrypoint.
public interface HostManagedChannelCleanupObserver {
    func observe(borrow:HostManagedChannelCleanupBorrow):Unit
}

public class HostManagedChannelCleanupState {
    public let borrowed:Int64
    public let paymentRetained:Bool
    public let released:Bool
    public let namespaceDescriptorsRetained:Bool
    public let processCloseAcknowledged:Bool
    public let physicalCloseHadError:Bool
    public let physicalCloseErrorRetained:Bool
    public let physicalClosePendingError:Bool
    public let pumpsJoined:Bool
    public let ioDrained:Bool
    init(borrowed:Int64,paymentRetained:Bool,released:Bool,namespaceDescriptorsRetained:Bool,
        processCloseAcknowledged:Bool,pumpsJoined:Bool,ioDrained:Bool,physicalCloseHadError!:Bool=false,physicalCloseErrorRetained!:Bool=false,physicalClosePendingError!:Bool=false){
        this.borrowed=borrowed;this.paymentRetained=paymentRetained;this.released=released
        this.namespaceDescriptorsRetained=namespaceDescriptorsRetained
        this.processCloseAcknowledged=processCloseAcknowledged;this.pumpsJoined=pumpsJoined;this.ioDrained=ioDrained
        this.physicalCloseHadError=physicalCloseHadError;this.physicalCloseErrorRetained=physicalCloseErrorRetained
        this.physicalClosePendingError=physicalClosePendingError
    }
}

// Scope witnesses contain no identity strings, Source or execution authority.
// Successful construction requires BOTH original current/Store Executing
// proofs and an actual cross-use attempt through the production prepare seam.
public class HostManagedChannelExecutingScopeState {
    public let sameRoot:Bool
    public let sameRun:Bool
    public let sameThread:Bool
    public let sameEpoch:Bool
    public let samePermissionDomain:Bool
    public let crossEffectRejected:Bool
    init(sameRoot:Bool,sameRun:Bool,sameThread:Bool,sameEpoch:Bool,samePermissionDomain:Bool){
        this.sameRoot=sameRoot;this.sameRun=sameRun;this.sameThread=sameThread;this.sameEpoch=sameEpoch
        this.samePermissionDomain=samePermissionDomain;crossEffectRejected=true
    }
}

// Constructors are package-private. This is a readonly custody loan over the
// exact grant/lease already adopted by the one original inventory. The loan
// uses the existing active counter and SAME payment; it has no close or ACK.
public class HostManagedChannelCleanupBorrow {
    private let actual:HostManagedProcessGrant
    private let lease:HostPluginLifecycleLease
    private let scopeLock=Mutex()
    private var scopeUsed=false
    init(actual:HostManagedProcessGrant,lease:HostPluginLifecycleLease){this.actual=actual;this.lease=lease}
    public func withCustodyBorrow(body:()->Result<Unit>):Result<Unit>{actual.withRetainedRuntime(body)}
    public func compareExecutingScope(other:HostManagedChannelCleanupBorrow):Result<HostManagedChannelExecutingScopeState>{
        if(refEq(this,other)){return hostLifecycleLeaseError("managed_channel.distinct_actual_scope_required")}
        scopeLock.lock();try{
            if(scopeUsed){return hostLifecycleLeaseError("managed_channel.scope_probe_already_used")}
            scopeUsed=true
        }finally{scopeLock.unlock()}
        actual.compareExecutingScope(other.actual,{action,peer=>lease.attemptManagedForeignScope(action,peer)})
    }
    public func withPhysicalCustodyBorrow(body:()->Result<Unit>):Result<Unit>{
        actual.withRetainedRuntime({=>lease.withManagedPhysicalCustodyBorrow(body)})
    }
    public func snapshot():HostManagedChannelCleanupState{
        let logical=actual.cleanupBorrowState()
        let physical=lease.managedCleanupPhysicalState()
        HostManagedChannelCleanupState(logical[0],logical[1],logical[2],logical[3],physical[0],physical[1],physical[2],physicalCloseHadError:physical[3],physicalCloseErrorRetained:physical[4],physicalClosePendingError:physical[5])
    }
}
