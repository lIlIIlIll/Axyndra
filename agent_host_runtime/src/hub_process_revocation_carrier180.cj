package agent_host_runtime

import std.sync.*

// Metadata is paid before construction and remains in the original producer
// registry. Once both Returning159 receipts are true, an unknown scheduler
// can retain only this fixed empty carrier, not an original Source/plan graph.
class HostHubProcessRevocationCarrier180{
    private let lock=Mutex()
    private var lease:?HostHubDerivedProcessLease180
    init(lease:HostHubDerivedProcessLease180){this.lease=Some(lease)}
    private func invokeWholeRevocationHelper180():Unit{
        let actual=lockAndBorrow180()
        match(actual){case Some(value)=>value.requestActualRevocation180();case None=>()}
    }
    private func lockAndBorrow180():?HostHubDerivedProcessLease180{
        lock.lock();try{lease}finally{lock.unlock()}
    }
    func invokeActualRevocation180():Unit{invokeWholeRevocationHelper180()}
    func clearAfterActualCallbacksReturned180():Unit{
        lock.lock();try{lease=None<HostHubDerivedProcessLease180>}finally{lock.unlock()}
    }
}
