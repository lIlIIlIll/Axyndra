# model_adapters

正式的 provider 边界实现。它直接消费 `agent_domain.ModelRequest`，负责
Messages/Responses 编解码、安全 HTTP 传输、fixture、重试与 fallback。

JSON AST 是本包内部实现；本包不依赖旧运行时。产品核心只依赖
`agent_ports.ModelPort`。
