package agent_product

import agent_history
import agent_domain.*
import yjson.*
import yjson_support.*

// The full and minimal applications share the same durable projection.
public type ProductRunInspectionProjection = agent_history.RunInspectionProjection

public func redactProductPlanInspection(state: AgentValue): AgentValue {
    agent_history.redactProductPlanInspection(state)
}
