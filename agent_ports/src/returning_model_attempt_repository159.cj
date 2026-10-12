package agent_ports

import agent_domain.*

// Explicit synchronous storage input retirement. The returned Result retains
// its original meaning; only the supplied input loan is acknowledged on Ok.
public interface ReturningModelAttemptRepository159 {
    func prepareModelAttemptReturning159(loan: ModelInputToolsBorrow159, attempt: DurableModelAttempt, event: AgentEvent, continuation: RunContinuation): Result<Unit>
    func prepareContextBoundaryModelAttemptReturning159(loan: ModelInputToolsBorrow159, expected: RunContextBoundary, attempt: DurableModelAttempt, event: AgentEvent, continuation: RunContinuation): Result<Unit>
    func prepareRestartModelAttemptReturning159(loan: ModelInputToolsBorrow159, parent: DurableModelAttempt, attempt: DurableModelAttempt, policyEvent: AgentEvent, duplicateEvent: AgentEvent, continuation: RunContinuation): Result<Unit>
}

public interface ReturningModelTranscriptPort159 {
    func transcriptSnapshotReturning159(request: ModelRequest, loan: ModelInputToolsBorrow159): ?String
}
