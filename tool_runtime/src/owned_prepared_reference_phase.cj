package tool_runtime

import agent_domain.*
import agent_runtime.*
import std.sync.*

// A real installed executor can opt into clearable Kernel callback fields.
// This is trusted in-process data custody, never a Native DTO/config flag.
// Existing Source/current/normal policy/handoff checks still run first.
public interface OwnedPreparedReferenceExecutor {
    func preparedReferenceCustody(context:ToolInvocationContext,
        parent:PreparedToolInvocation):Result<OwnedKernelPreparedReferenceCustody>
}
public interface OwnedKernelPreparedReferenceCustody <: LiveToolExecutionCustody & OwnedPendingPreparedAliasCustody {
    // Adopt in the SAME actual Host collector before this frame escapes.
    // Its conservative pin cannot be discarded during Run settlement.
    func adoptKernelPreparedReferenceDebt(debt:OwnedKernelPreparedReferenceDebt):Result<Unit>
}

// A Kernel-only scope witness, distinct from the Host metadata retirement
// token. It proves these mutable fields are None after its admitted callback frames
// ended, with retained child/resource fields also cleared. It DOES NOT prove Host grants/accepted children/Source captures died
// and cannot unlock pendingPreparedAliasesRetired or refund their backing.
public class OwnedKernelPreparedControlFieldsWitness {
    private let actual:OwnedKernelPreparedReferenceDebt
    private init(actual:OwnedKernelPreparedReferenceDebt){this.actual=actual}
    static func issue(actual:OwnedKernelPreparedReferenceDebt):Result<OwnedKernelPreparedControlFieldsWitness>{
        if(!actual.referencesCleared()){return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
            "tool.prepared_reference_scope_live","actual Kernel control still owns reference fields"))}
        Result.Ok(OwnedKernelPreparedControlFieldsWitness(actual))
    }
    public func isControlFieldsCleared():Bool{actual.referencesCleared()}
}

// Full payment stays alive after fields clear. No public close/refund, no
// Source/effect identity, no Prepared getter, no arbitrary receipt/Bool ACK.
// The future actual Host+Core alias migration must retire its independent
// escapers before this conservative same-bank pin can be released.
public class OwnedKernelPreparedReferenceDebt {
    private let lock=Mutex()
    private let backing:LogicalJsonOwnerReservation
    private let actualCustody:OwnedKernelPreparedReferenceCustody
    private var parent:?PreparedToolInvocation
    private var resumed:?PreparedToolInvocation
    private var child:?PreparedToolInvocation=None<PreparedToolInvocation>
    private var peak:Int64
    private var check:?(() -> Result<Unit>)=None<(() -> Result<Unit>)>
    private var prepare:?((ToolInvocationContext,ToolCall,String)->Result<ToolPreparation>)=None<((ToolInvocationContext,ToolCall,String)->Result<ToolPreparation>)>
    private var capture:?((PreparedToolInvocation,LiveToolExecutionCustody)->Result<OwnedToolExecutionContinuation>)=None<((PreparedToolInvocation,LiveToolExecutionCustody)->Result<OwnedToolExecutionContinuation>)>
    private var execute:?((ToolInvocationContext,PreparedToolInvocation)->Result<ToolInvocationResult>)=None<((ToolInvocationContext,PreparedToolInvocation)->Result<ToolInvocationResult>)>
    private var retained:?((ToolInvocationContext,PreparedToolInvocation,LiveToolExecutionCustody)->Result<OwnedToolRetainedChildExecution>)=None<((ToolInvocationContext,PreparedToolInvocation,LiveToolExecutionCustody)->Result<OwnedToolRetainedChildExecution>)>
    private var installed=false
    private var cleared=false
    private var retainedControlFieldsCleared=false
    init(backing:LogicalJsonOwnerReservation,actualCustody:OwnedKernelPreparedReferenceCustody,parent:PreparedToolInvocation,
        resumed:?PreparedToolInvocation,peak:Int64){
        this.backing=backing;this.actualCustody=actualCustody;this.parent=Some(parent);this.resumed=resumed;this.peak=peak
    }
    func install(check:()->Result<Unit>,prepare:(ToolInvocationContext,ToolCall,String)->Result<ToolPreparation>,
        capture:(PreparedToolInvocation,LiveToolExecutionCustody)->Result<OwnedToolExecutionContinuation>,
        execute:(ToolInvocationContext,PreparedToolInvocation)->Result<ToolInvocationResult>,
        retained:?((ToolInvocationContext,PreparedToolInvocation,LiveToolExecutionCustody)->Result<OwnedToolRetainedChildExecution>)):Unit{
        lock.lock();try{
            if(installed || cleared){throw IllegalStateException("prepared reference callbacks cannot be installed twice")}
            this.check=Some(check);this.prepare=Some(prepare);this.capture=Some(capture)
            this.execute=Some(execute);this.retained=retained;installed=true
        }finally{lock.unlock()}
    }
    func matchesCustody(actual:LiveToolExecutionCustody):Bool{sameLiveToolExecutionCustody(actualCustody,actual)}
    func actualCheck():()->Result<Unit>{check.getOrThrow()}
    func actualPrepare():(ToolInvocationContext,ToolCall,String)->Result<ToolPreparation>{prepare.getOrThrow()}
    func actualCapture():(PreparedToolInvocation,LiveToolExecutionCustody)->Result<OwnedToolExecutionContinuation>{capture.getOrThrow()}
    func actualExecute():(ToolInvocationContext,PreparedToolInvocation)->Result<ToolInvocationResult>{execute.getOrThrow()}
    func actualRetained():?((ToolInvocationContext,PreparedToolInvocation,LiveToolExecutionCustody)->Result<OwnedToolRetainedChildExecution>){retained}
    func actualParent():?PreparedToolInvocation{parent}
    func actualResumed():?PreparedToolInvocation{resumed}
    func prepayChildReference(actual:PreparedToolInvocation,waiting:Bool):Result<Unit>{
        lock.lock();try{
            if(cleared || child.isSome()){return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "tool.prepared_reference_scope_changed","a selected pending child freezes this invocation"))}
            try{
                let measure=OwnedPreparedReferenceMeasure(backing,peak);measure.prepared(actual)
                let additional=measure.peak()
                if(additional>Int64.Max-peak){throw LogicalJsonPayloadError("prepared reference extent overflow")}
                backing.ensureRetainedPeak(peak+additional)
                // Entire payment precedes the actual child/reference capture.
                peak+=additional;if(waiting){child=Some(actual)};Result.Ok(())
            }catch(_:OwnedPreparedOpaqueReferenceError){Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "tool.prepared_reference_opaque_source","actual opaque Source/read ownership is not installed"))}
            catch(_:Exception){Result.Err(AgentError(AgentErrorKind.BudgetExceeded,
                "tool.prepared_reference_capacity","complete pending Prepared data is not prepaid"))}
        }finally{lock.unlock()}
    }
    func prepayPreparation(preparation:Result<ToolPreparation>):Result<ToolPreparation>{
        let paid=match(preparation){
            case Result.Ok(ToolPreparation.Ready(actual))=>prepayChildReference(actual,false)
            case Result.Ok(ToolPreparation.NeedsApproval(actual,_))=>prepayChildReference(actual,false)
            case _=>Result<Unit>.Ok(())}
        match(paid){case Result.Err(error)=>Result.Err(error);case Result.Ok(_)=>preparation}
    }
    func clearAfterInvocation(retainedFieldsCleared:Bool):Unit{
        lock.lock();try{
            // Caller holds Control lock, after every admitted callback has
            // returned. Clear real closure fields and data references first.
            check=None<(() -> Result<Unit>)>;prepare=None<((ToolInvocationContext,ToolCall,String)->Result<ToolPreparation>)>
            capture=None<((PreparedToolInvocation,LiveToolExecutionCustody)->Result<OwnedToolExecutionContinuation>)>
            execute=None<((ToolInvocationContext,PreparedToolInvocation)->Result<ToolInvocationResult>)>
            retained=None<((ToolInvocationContext,PreparedToolInvocation,LiveToolExecutionCustody)->Result<OwnedToolRetainedChildExecution>)>
            parent=None<PreparedToolInvocation>;resumed=None<PreparedToolInvocation>;child=None<PreparedToolInvocation>;cleared=true;retainedControlFieldsCleared=retainedFieldsCleared
            // Do not close backing: immutable legacy publication, Host live
            // grants, Context handlers and permanent Root aliases remain OPEN.
        }finally{lock.unlock()}
    }
    func referencesCleared():Bool{lock.lock();try{cleared && retainedControlFieldsCleared && parent.isNone() && resumed.isNone() && child.isNone() &&
        check.isNone() && prepare.isNone() && capture.isNone() && execute.isNone() && retained.isNone()}finally{lock.unlock()}}
    public func controlFieldsWitness():Result<OwnedKernelPreparedControlFieldsWitness>{OwnedKernelPreparedControlFieldsWitness.issue(this)}
    public func closeAfterScopeRetirement():Result<Unit>{Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
        "tool.prepared_reference_escapers_pending","Kernel fields cleared; independent Host/Source/parent aliases remain paid debt"))}
}

// Package-private creator; no caller-supplied bill, pool or Source factory.
func retainOwnedKernelPreparedReferenceDebt(actual:OwnedKernelPreparedReferenceCustody,
    parent:PreparedToolInvocation,resumed:?PreparedToolInvocation):Result<OwnedKernelPreparedReferenceDebt>{
    let child=match(resumed){case Some(value)=>value;case None=>parent}
    let paid=actual.retainPendingPreparedAliases(parent,child)
    let backing=match(paid){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    var adopted=false
    try{
        backing.ensureRetainedPeak(8192)
        let measure=OwnedPreparedReferenceMeasure(backing,8192);measure.prepared(parent)
        match(resumed){case Some(value)=>measure.prepared(value);case None=>()}
        let peak=measure.peak();backing.ensureRetainedPeak(peak)
        let debt=OwnedKernelPreparedReferenceDebt(backing,actual,parent,resumed,peak)
        // From this call onward the same actual collector must retain debt
        // even when adoption reports an error; never refund escaped aliases.
        adopted=true
        match(actual.adoptKernelPreparedReferenceDebt(debt)){
            case Result.Err(error)=>Result.Err(error);case Result.Ok(_)=>Result.Ok(debt)}
    }catch(_:OwnedPreparedOpaqueReferenceError){Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
        "tool.prepared_reference_opaque_source","actual opaque Source/read ownership is not installed"))}
    catch(_:Exception){Result.Err(AgentError(AgentErrorKind.BudgetExceeded,
        "tool.prepared_reference_capacity","complete Kernel Prepared references could not be prepaid"))}
    finally{if(!adopted){backing.close()}}
}
