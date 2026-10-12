package agent_runtime

import agent_domain.*

public interface ReturningModelDecisionRuntime159 {
    func createAttemptReturning159(attempt: DurableModelAttempt, loan: ModelInputToolsBorrow159): Result<Unit>
}
