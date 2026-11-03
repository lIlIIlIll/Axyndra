package tool_runtime

import agent_domain.*
import agent_runtime.*
import agent_ports.*

// Actual Catalog-selected data funding. This method does not prepare a
// Source, approve a plan, execute IO, settle a Receipt or acknowledge debt.
// The trusted Host retains the same original Session and all issued loans.
public interface OwnedPreparationInputExecutor340 {
    func retainPreparationInput340(context:ToolInvocationContext,root:?OperationRootSource,
        call:ToolCall,facts:Array<ContextReadFactLink>):Result<Unit>
}

// Only a real installed effect executor selects the complete native-abort
// Receipt verifier. A result flag, error message or caller DTO cannot select it.
public interface NativeAbortOwnedToolEffectExecutor340 <: RetainedOwnedToolEffectExecutor {}

public func ownedPreparationInputInvoice340(backing:LogicalJsonOwnerReservation,
    context:ToolInvocationContext,root:?OperationRootSource,call:ToolCall,facts:Array<ContextReadFactLink>):Result<Int64>{
    try{
        backing.ensureRetainedPeak(8192)
        let measure=OwnedPreparedReferenceMeasure(backing,8192)
        measure.preparationInput340(context,root,call,facts)
        let peak=measure.peak();backing.ensureRetainedPeak(peak);Result<Int64>.Ok(peak)
    }catch(_:OwnedPreparedOpaqueReferenceError){
        ownedPreparedWaitingError<Int64>("tool.preparation_opaque_source")}
    catch(_:Exception){ownedPreparedWaitingError<Int64>("tool.preparation_input_unpaid")}
}
