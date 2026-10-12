package agent_runtime

import agent_domain.*
import std.sync.*

// Allocation and lexical return only. No Source/approval/Receipt/data ACK.
// Store binds this exact object only while constructing its real paid debt.
// An empty callback or another frame cannot replace that private binding.
public class PluginLivePolicyOuterErrorFrame334 {
    private let lock=Mutex()
    private let payment:LogicalJsonOwnerReservation
    private var entered=false
    private var invoking=false
    private var returned=false
    private init(payment:LogicalJsonOwnerReservation){this.payment=payment}
    public static func retain(original:LogicalJsonOwnerReservation):PluginLivePolicyOuterErrorFrame334{
        let paid=original.deriveRetainedLease();var captured=false
        try{
            paid.ensureRetainedPeak(4096)
            let value=PluginLivePolicyOuterErrorFrame334(paid);captured=true;value
        }finally{if(!captured){paid.close()}}
    }
    public func invoke<T>(action:(PluginLivePolicyOuterErrorFrame334)->T):T{
        lock.lock();try{
            if(entered){throw IllegalStateException("actual paid error frame cannot be reused")}
            entered=true;invoking=true
        }finally{lock.unlock()}
        var completed=false
        try{let result=action(this);completed=true;result}
        finally{lock.lock();try{invoking=false;returned=completed}finally{lock.unlock()}}
    }
    public func isInvoking():Bool{lock.lock();try{invoking && !returned}finally{lock.unlock()}}
    public func hasReturned():Bool{lock.lock();try{returned && !invoking}finally{lock.unlock()}}
    // No close/refund. The real custody and copied error retain this paid
    // wrapper after callback return; caller/Source/Prepared aliases stay paid.
}
