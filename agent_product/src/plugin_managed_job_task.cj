package agent_product

import agent_domain.*
import agent_runtime.*

class ProductManagedJobHandle {
    let reservation: ManagedJobReservation
    let budget: ExecutionBudget
    let operationId: OperationId
    let acknowledged: () -> Bool
    var admission: ?ManagedJobAdmission = None
    init(reservation: ManagedJobReservation, budget: ExecutionBudget, operationId: OperationId, acknowledged: () -> Bool) {
        this.reservation = reservation; this.budget = budget; this.operationId = operationId; this.acknowledged = acknowledged
    }
}


