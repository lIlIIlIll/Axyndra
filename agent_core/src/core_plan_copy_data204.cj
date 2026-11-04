package agent_core

import agent_domain.*
import tool_runtime.*

// A DATA-only linked cell. Its header is invoiced before allocation in the
// actual control's Catalog-derived metadata payment. The retained payment
// funds the complete roots/IDs copies; no execution authority lives here.
class CorePlanCopyAllocation204 {
    let payment: LogicalJsonOwnerReservation
    var next204: ?CorePlanCopyAllocation204
    init(payment: LogicalJsonOwnerReservation, next: ?CorePlanCopyAllocation204) {
        this.payment = payment; this.next204 = next
    }
}

// The counted Catalog source is DATA only; its real whole-Run return proof
// remains in CoreRunControl rather than in this prepaid list cell.
class CoreCatalogSource204 {
    let scope: ToolCatalogCoreDataScope204
    var next204: ?CoreCatalogSource204
    init(scope: ToolCatalogCoreDataScope204, next: ?CoreCatalogSource204) {
        this.scope = scope; this.next204 = next
    }
}
