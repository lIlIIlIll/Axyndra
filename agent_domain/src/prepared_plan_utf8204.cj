package agent_domain

// Independent copied DATA only. Numeric reads never expose the producer's
// Array/String/Plan/Catalog graph. A receiver pays its actual private copies
// before allocating them and owns their separate complete-consumer lifetime.
// There is no Source, DB, Run, capability, approval or consumer ACK here.
public interface PreparedPlanUtf8Owner204 {
    prop byteCount: Int64
    func byteAt(index: Int64): UInt8
    func deriveCopiedPlanPayment204(invoice: Int64): LogicalJsonOwnerReservation
}

public interface CatalogAuditEventDataPort204 {
    func appendCatalogAuditOwnedUtf8204(value: PreparedPlanUtf8Owner204): Result<Unit>
}

public interface CatalogPermissionGrantDataPort204 {
    func allowsCatalogGrantOwnedUtf8204(sessionId: SessionId, value: PreparedPlanUtf8Owner204): Result<Bool>
    func grantCatalogGrantOwnedUtf8204(sessionId: SessionId, value: PreparedPlanUtf8Owner204): Result<Unit>
}
