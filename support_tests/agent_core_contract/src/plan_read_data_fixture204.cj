package agent_core_contract

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import yjson.*
import yjson_support.*
import std.collection.*

// Actual original-bank DATA accounting for isolated descriptor tests. These
// fixtures do not attest Native publication or replace canonical Store proof.
class PlanBatchReadPayment204 <: ToolCatalogDataPayment159 & ToolCatalogSnapshotPayment159 {
    let bank: LogicalJsonOwnerBudget
    private let ancestor: LogicalJsonOwnerReservation
    init() {
        let original = LogicalJsonOwnerBudget(maximumCharged: 67108864)
        let paid = original.acquire(4096)
        this.bank = original; this.ancestor = paid
    }
    func currentInvoice240(): Int64 { ancestor.retainedCustodyUsage113()[0] }
    public func reserveCatalogData159(bytes: Int64): Unit { ancestor.ensureRetainedPeak(bytes) }
    public func reserveTemporaryCatalogData159(bytes: Int64): ToolCatalogTemporaryData159 {
        PlanBatchReadTemporary204(child204(bytes))
    }
    public func reserveSnapshotCatalogData159(bytes: Int64): LogicalJsonOwnerReservation { child204(bytes) }
    public func snapshotCatalogDataInvoice159(): Int64 { 65536 }
    private func child204(bytes: Int64): LogicalJsonOwnerReservation {
        let value = ancestor.deriveRetainedLease()
        value.ensureRetainedPeak(max(4096, bytes)); value
    }
}
class PlanBatchReadTemporary204 <: ToolCatalogTemporaryData159 {
    private let payment: LogicalJsonOwnerReservation
    init(payment: LogicalJsonOwnerReservation) { this.payment = payment }
    public func returnedTemporaryHelper159(): Unit { payment.close() }
    public func newBacking159(bytes: Int64): ToolCatalogBackingData159 {
        let child = payment.deriveRetainedLease(); child.ensureRetainedPeak(bytes)
        PlanBatchReadBacking204(child)
    }
    public func prepareBackingPublication159(_: ?ToolCatalogBackingData159): Unit {}
}
class PlanBatchReadBacking204 <: ToolCatalogBackingData159 {
    private let payment: LogicalJsonOwnerReservation
    init(payment: LogicalJsonOwnerReservation) { this.payment = payment }
    public func growBacking159(bytes: Int64): Unit { payment.ensureRetainedPeak(bytes) }
    public func retainUnknownBacking159(): Unit {}
}
func planBatchReadCatalog204(): ToolCatalog {
    let catalog = ToolCatalog()
    let descriptor = ToolDescriptor(ModelToolDefinition("fixture_plan_data_anchor", "DATA fixture", objectValue([])),
        Capability(CapabilityKind.WorkspaceRead), hostServiceOnly: true)
    catalog.registerBatch([ToolCatalogRegistration(descriptor, PlanBatchReadExecutor())],
        dataPayment: Some(PlanBatchReadPayment204())).value().getOrThrow()
    catalog
}
