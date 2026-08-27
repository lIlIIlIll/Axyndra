package agent_mcp

import agent_domain.*
import mcp4cj as library

public let MCP_PROTOCOL_VERSION = library.MCP_PROTOCOL_VERSION
public let MCP_HEADER_PROTOCOL_VERSION = library.MCP_HEADER_PROTOCOL_VERSION
public let MCP_HEADER_METHOD = library.MCP_HEADER_METHOD
public let MCP_HEADER_NAME = library.MCP_HEADER_NAME
public let MCP_HEADER_PARAM_PREFIX = library.MCP_HEADER_PARAM_PREFIX
public let MCP_META_PROTOCOL_VERSION = library.MCP_META_PROTOCOL_VERSION
public let MCP_META_CLIENT_INFO = library.MCP_META_CLIENT_INFO
public let MCP_META_CLIENT_CAPABILITIES = library.MCP_META_CLIENT_CAPABILITIES
public let MCP_META_SERVER_INFO = library.MCP_META_SERVER_INFO
public let MCP_HEADER_MISMATCH: Int64 = library.MCP_HEADER_MISMATCH
public let MCP_MISSING_REQUIRED_CLIENT_CAPABILITY: Int64 = library.MCP_MISSING_REQUIRED_CLIENT_CAPABILITY
public let MCP_UNSUPPORTED_PROTOCOL_VERSION: Int64 = library.MCP_UNSUPPORTED_PROTOCOL_VERSION
public let MCP_RESULT_COMPLETE = library.MCP_RESULT_COMPLETE
public let MCP_RESULT_INPUT_REQUIRED = library.MCP_RESULT_INPUT_REQUIRED
public let MCP_METHOD_DISCOVER = library.MCP_METHOD_DISCOVER
public let MCP_METHOD_TOOLS_LIST = library.MCP_METHOD_TOOLS_LIST
public let MCP_METHOD_TOOLS_CALL = library.MCP_METHOD_TOOLS_CALL
public let MCP_METHOD_CANCELLED = library.MCP_METHOD_CANCELLED
public let MCP_METHOD_COMPLETION_COMPLETE = library.MCP_METHOD_COMPLETION_COMPLETE
public let MCP_METHOD_PROMPTS_LIST = library.MCP_METHOD_PROMPTS_LIST
public let MCP_METHOD_PROMPTS_GET = library.MCP_METHOD_PROMPTS_GET
public let MCP_METHOD_RESOURCES_LIST = library.MCP_METHOD_RESOURCES_LIST
public let MCP_METHOD_RESOURCE_TEMPLATES_LIST = library.MCP_METHOD_RESOURCE_TEMPLATES_LIST
public let MCP_METHOD_RESOURCES_READ = library.MCP_METHOD_RESOURCES_READ
public let MCP_METHOD_SUBSCRIPTIONS_LISTEN = library.MCP_METHOD_SUBSCRIPTIONS_LISTEN
public let MCP_METHOD_ROOTS_LIST = library.MCP_METHOD_ROOTS_LIST
public let MCP_METHOD_SAMPLING_CREATE_MESSAGE = library.MCP_METHOD_SAMPLING_CREATE_MESSAGE
public let MCP_METHOD_ELICITATION_CREATE = library.MCP_METHOD_ELICITATION_CREATE

public type McpImplementationInfo = library.McpImplementationInfo
public type McpRequestMeta = library.McpRequestMeta
public type McpServerCapabilities = library.McpServerCapabilities
public type McpCapabilityFeature = library.McpCapabilityFeature
public type McpClientCapabilities = library.McpClientCapabilities
public type McpRootsCapability = library.McpRootsCapability
public type McpSamplingCapability = library.McpSamplingCapability
public type McpElicitationCapability = library.McpElicitationCapability
public type McpDiscoverResult = library.McpDiscoverResult
public type McpTool = library.McpTool
public type McpToolListPage = library.McpToolListPage
public type McpCallToolResult = library.McpCallToolResult
public type McpInputRequiredResult = library.McpInputRequiredResult
public type McpToolCallContinuation = library.McpToolCallContinuation
public type McpCallToolOutcome = library.McpCallToolOutcome
public type McpToolDirectorySnapshot = library.McpToolDirectorySnapshot
public type McpToolDirectoryCache = library.McpToolDirectoryCache
public type McpPromptArgument = library.McpPromptArgument
public type McpPrompt = library.McpPrompt
public type McpResource = library.McpResource
public type McpResourceTemplate = library.McpResourceTemplate
public type McpPage = library.McpPage
public type McpCompletionResult = library.McpCompletionResult
public type McpPromptResult = library.McpPromptResult
public type McpReadResourceResult = library.McpReadResourceResult
public type McpOperationOutcome<T> = library.McpOperationOutcome<T>
public type McpInputResolver = library.McpInputResolver
public type McpResolutionPolicy = library.McpResolutionPolicy
public type McpInputRequest = library.McpInputRequest
public type McpInputResponse = library.McpInputResponse
public type McpSubscriptionFilter = library.McpSubscriptionFilter
public type McpSubscriptionHandle = library.McpSubscriptionHandle
public type McpTask = library.McpTask
public type McpTaskStatus = library.McpTaskStatus

public func mcpCallToolOutcomeValue(outcome: McpCallToolOutcome): AgentValue {
    library.mcpCallToolOutcomeValue(outcome)
}
