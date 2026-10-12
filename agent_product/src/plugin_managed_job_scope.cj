package agent_product

import agent_host_runtime

import agent_host_runtime.*

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import yjson.*
import yjson_support.*

// A live Runtime seal selects the original resource domain while the actual
// invocation keeps the child Thread/Run/epoch/token. Descriptive metadata and
// preparation_ref alone can never open this route.
func productManagedJobSource(source: ?OperationRootSource): ?DirectToolCallRef {
    agent_host_runtime.hostManagedJobSource(source)
}

func validateManagedJobResource(context: ToolInvocationContext, source: ?OperationRootSource,
    target: ThreadId, domain: String, binding!: ?AgentValue = None): Result<Unit> {
    agent_host_runtime.hostValidateManagedJobResource(context, source, target, domain, binding: binding)
}

func managedServiceExecutionArguments(localName: String, prepared: PreparedToolInvocation): AgentValue {
    agent_host_runtime.hostManagedServiceExecutionArguments(localName, prepared)
}
