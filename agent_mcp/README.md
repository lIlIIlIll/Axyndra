# agent_mcp

仓颉实现的 MCP `2026-07-28` client/server：

- `server/discover`、分页 `tools/list`、`tools/call` 与 cancellation；
- namespaced `_meta`、`resultType`、typed `input-required` 与使用新 request ID 的 MRTR；
- 真实 child-process stdio transport，stdout 只承载 JSON-RPC；
- 原生 `stdx.net.http` Streamable HTTP POST，支持 JSON/SSE 响应；
- bearer/header 只绑定环境变量名，Origin 精确 allowlist，redirect fail-closed；
- `tools/call` 发送后响应丢失返回 `RecoveryRequired`，不会自动重试潜在副作用。

本实现不保留已退出当前规范的 `initialize`、Session-Id、DELETE lifecycle 或伪
subscription 方法。远端 JSON-RPC `error.data.code` 会经过大小/类型限制后保真为
可处理的 `AgentError.code`，而不是坍缩成一个通用协议错误。
产品通过 `agent_extensions` 将远端 MCP tool 映射成普通 `ToolDescriptor`，因此仍然
经过 capability、approval、receipt 和 audit。
