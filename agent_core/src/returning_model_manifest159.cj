package agent_core

import agent_domain.*
import agent_runtime.*

// The actual implementation must let its complete compiler/SQL helper return
// and keep failures paid. An ordinary Result<Unit> port gets no implicit ACK.
public interface ReturningModelContextManifestRuntime159 {
    func recordBeforeModelEffectWithOwnedLane159(loan: ?ModelInputToolsBorrow159,
        active: OwnedActiveRunFrame159, request: AgentRunRequest, requestId: RequestId,
        stepId: StepId, stepOrdinal: Int64, projection: ModelContextProjection,
        renderedRequest: AgentValue, estimatedInputTokens: Int64, observedAtMillis: Int64): Result<Unit>
    func recordBeforeModelEffectReturning159(loan: ModelInputToolsBorrow159,
        request: AgentRunRequest, requestId: RequestId, turnId: SemanticTurnId,
        executionLaneId: LaneId, stepId: StepId, stepOrdinal: Int64,
        projection: ModelContextProjection, lane: ModelLane, renderedRequest: AgentValue,
        estimatedInputTokens: Int64, observedAtMillis: Int64): Result<Unit>
}
