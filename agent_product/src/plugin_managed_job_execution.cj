package agent_product

import agent_domain.*
import tool_runtime.*

class ProductManagedJobExecution {
    let result: Result<ToolInvocationResult>
    let usage: ExecutionUsage
    let settled: Bool
    let operationId: OperationId
    init(result: Result<ToolInvocationResult>, usage: ExecutionUsage, settled: Bool, operationId: OperationId) {
        this.result = result; this.usage = usage; this.settled = settled; this.operationId = operationId
    }
}
