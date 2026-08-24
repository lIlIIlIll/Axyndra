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
public let MCP_METHOD_PING = library.MCP_METHOD_PING
public let MCP_METHOD_TOOLS_LIST = library.MCP_METHOD_TOOLS_LIST
public let MCP_METHOD_TOOLS_CALL = library.MCP_METHOD_TOOLS_CALL
public let MCP_METHOD_CANCELLED = library.MCP_METHOD_CANCELLED

public type McpImplementationInfo = library.McpImplementationInfo
public type McpRequestMeta = library.McpRequestMeta
public type McpServerCapabilities = library.McpServerCapabilities
public type McpDiscoverResult = library.McpDiscoverResult
public type McpTool = library.McpTool
public type McpToolListPage = library.McpToolListPage
public type McpCallToolResult = library.McpCallToolResult
public type McpInputRequiredResult = library.McpInputRequiredResult
public type McpToolCallContinuation = library.McpToolCallContinuation
public type McpCallToolOutcome = library.McpCallToolOutcome
public type McpToolDirectorySnapshot = library.McpToolDirectorySnapshot
public type McpToolDirectoryCache = library.McpToolDirectoryCache

public func mcpCallToolOutcomeValue(outcome: McpCallToolOutcome): AgentValue {
    library.mcpCallToolOutcomeValue(outcome)
}
