package agent_domain

import logical_json_payload as payload

public type LogicalJsonCopiedDisplayAllocation = payload.LogicalJsonCopiedDisplayAllocation

func logicalJsonCopiedDisplayError<T>(code: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired, code,
        "copied display data requires its actual original-bank allocation and retirement",
        retryable: false, fallbackAllowed: false))
}

func logicalJsonCopiedDisplayResult126<T>(actual: payload.PayloadDataResult<T>): Result<T> {
    match (actual) {
        case payload.PayloadDataResult.Ok(value) => Result.Ok(value)
        case payload.PayloadDataResult.Err(code) => logicalJsonCopiedDisplayError<T>(code)
    }
}

func logicalJsonCopiedDisplayBorrowFailure126(code: String): Result<Unit> {
    logicalJsonCopiedDisplayError<Unit>(code)
}

// Imported data-only interfaces make these existing cross-package extensions visible.
// Allocation, error mapping, borrowing and retirement stay in their original bodies.
public interface LogicalJsonCopiedDisplayOwnerPort {
    func acquireCopiedDisplayAllocation(totalInvoice: Int64): Result<LogicalJsonCopiedDisplayAllocation>
}

public interface LogicalJsonCopiedDisplayAllocationPort {
    func ensureCopiedDisplayRetainedPeak(totalInvoice: Int64): Result<Unit>
    func retainCopiedDisplayAllocation(): Result<LogicalJsonCopiedDisplayAllocation>
    func withCopiedDisplayBorrow(consume: () -> Result<Unit>): Result<Unit>
    func closeAfterCopiedDisplayRetirement(): Result<Unit>
}

// Extensions preserve the original Domain result contract and error fields.
// Their receiver is the actual neutral object, not another allocation owner.
extend LogicalJsonOwnerReservation <: LogicalJsonCopiedDisplayOwnerPort {
    public func acquireCopiedDisplayAllocation(totalInvoice: Int64): Result<LogicalJsonCopiedDisplayAllocation> {
        logicalJsonCopiedDisplayResult126(this.acquireCopiedDisplayAllocationData(totalInvoice))
    }
}
extend LogicalJsonCopiedDisplayAllocation <: LogicalJsonCopiedDisplayAllocationPort {
    public func ensureCopiedDisplayRetainedPeak(totalInvoice: Int64): Result<Unit> {
        logicalJsonCopiedDisplayResult126(this.ensureCopiedDisplayRetainedPeakData(totalInvoice))
    }
    public func retainCopiedDisplayAllocation(): Result<LogicalJsonCopiedDisplayAllocation> {
        logicalJsonCopiedDisplayResult126(this.retainCopiedDisplayAllocationData())
    }
    public func withCopiedDisplayBorrow(consume: () -> Result<Unit>): Result<Unit> {
        // The actual callback result, including all eight AgentError fields,
        // passes through as T. It is never reconstructed from code or text.
        this.withCopiedDisplayBorrowData<Result<Unit>>(consume, logicalJsonCopiedDisplayBorrowFailure126)
    }
    public func closeAfterCopiedDisplayRetirement(): Result<Unit> {
        logicalJsonCopiedDisplayResult126(this.closeAfterCopiedDisplayRetirementData())
    }
}
