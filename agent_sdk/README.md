# agent_sdk

可嵌入式 Agent SDK。`AgentBuilder` 显式要求 Provider、ModelCapabilities、
ToolCatalog、Conversation/Run/Operation repositories、policy、budget、prompt、
audit 和 ID generator，然后只组合仓库中的唯一 `AgentCore`。

`AgentSdk.run` 与 `continueApproval` 返回类型化结果；`CancellationToken` 会传播到
活动 model/tool。`HeadlessRunner` 提供稳定状态、exit code 和 UTF-8 JSONL 事件。
配置值携带 `Default < File < Environment < Cli < Programmatic` 来源，secret 标记
只能保持或增强，诊断描述不会打印 prompt 或凭据。

`AgentBuilder.structuredOutput` 绑定 provider-neutral JSON Schema，Runtime 会在返回
调用方前再次验证实际 JSON；`cachePolicy(StablePrefix)` 使用确定性 Prompt 前缀哈希，
不会把 Provider 缓存参数泄漏进 Core。`AgentSdk.runWithImages` 接受受限的 HTTP(S) URL
或最多 20 MiB 的 typed Base64 图像，并在请求前校验模型的 Vision capability。
`AgentBuilder.toolContext` 显式提供 workspace/cwd、过滤后的环境、服务描述；活动
CancellationToken 仍由唯一 `AgentCore` 在每次 run/approval resume 时绑定。

测试可直接配合 `agent_testkit` 的 scripted provider、内存仓储和确定性 ID。

当前 SDK 版本是 `2.0.0`。这是迁移到 yjson 后的破坏性版本；扩展 manifest 必须声明
`[2.0.0, 3.0.0)`。SDK 1 范围不会被运行时自动兼容或隐式升级。
