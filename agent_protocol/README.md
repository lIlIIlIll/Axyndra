# agent_protocol

传输无关的 JSON-RPC 2.0 值、编解码、错误与 request ID 关联状态。该包不依赖
MCP、HTTP、stdio 或产品代码；`agent_mcp` 在此边界之上定义协议方法和生命周期。

解码器对 frame/value 大小、非法 envelope、重复/未知关联和 cancellation 做显式
校验，预期协议失败返回 `Result<T>`。
