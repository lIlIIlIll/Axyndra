package tool_runtime

import agent_domain.*
import agent_runtime.*

// DATA only. Core's actual control implements this on the existing private
// Registry bank. Neither method authorizes a Tool, Source, Run or Operation.
public interface PlanCopyDataConsumer204 {
    func retainCatalogSource204(runId: RunId, scope: ToolCatalogCoreDataScope204): Unit
    func derivePlanWireAllocation204(runId: RunId, invoice: Int64): LogicalJsonOwnerReservation
    func retainPlanReadAllocation204(runId: RunId, payment: LogicalJsonOwnerReservation): Unit
}

// The actual Core control must be a reference object. A value-type interface
// implementation cannot impersonate its identity through equal fields/hash.
func samePlanCopyConsumer204(left: PlanCopyDataConsumer204, right: PlanCopyDataConsumer204): Bool {
    match (left as Object) {
        case Some(actual) => match (right as Object) { case Some(expected) => refEq(actual, expected); case None => false }
        case None => false
    }
}
