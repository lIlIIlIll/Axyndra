package agent_runtime

import agent_domain.*

// Allocation and fixed-file custody only. This interface does not create a
// Source, approval, execution handoff, Receipt or canonical result. The real
// Store independently verifies all of those in its same transaction.
public interface OperationTerminalDataOwner {
    func withRetainedOutput(lease:ToolResultPayloadLease,
        consume:(AgentValue,LogicalJsonOwnerReservation,Int64,()->Result<Unit>)->Unit):Result<Unit>
    // Ordinary default is closed. Unit allocation release is not evidence of
    // physical Session cleanup; only the actual resource owner can ACK it.
    func closeRetainedOutput(actual:ToolResultPayloadLease):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"operation.terminal_output_close_unavailable",
            "this terminal data owner cannot acknowledge its actual retained output"))
    }
}

// Explicit trusted in-process opt-in. The ordinary owner stays default closed.
// This marker grants no Source, approval, Known receipt or replay authority.
public interface AcknowledgedOperationTerminalDataOwner <: OperationTerminalDataOwner {
    // The actual decoded output reservation, never the bounded descriptor
    // metadata reservation. Kernel retains this SAME backing after Session
    // ACK while canonical/snapshot/extracted value aliases remain possible.
    func retainCanonicalBacking(actual:ToolResultPayloadLease):Result<LogicalJsonOwnerReservation>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"operation.canonical_backing_unavailable",
            "actual decoded output backing must remain paid before canonical aliases are created"))
    }
    // Pre-output resource failure may have no payload allocation at all. A
    // real owner must close its SAME actual unpublished Session/resources;
    // no synthetic lease can stand in for that acknowledgement.
    func closeUnpublishedOutput():Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"operation.unpublished_output_close_unavailable",
            "same actual unpublished resources remain owned until physical acknowledgement"))
    }
}
