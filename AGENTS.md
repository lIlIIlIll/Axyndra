# AGENTS.md

## 产品与架构

- 以 `README.md`、`CONTEXT.md`、`docs/architecture.md`、已接受的 ADR、当前 Issue 与源码为依据。不要把别的 Agent 产品或旧讨论当作当前实现的真值。
- `agent_core` 是唯一 Agent loop；协议、Provider 适配、tool/skill/plugin、subagent、会话存储、沙箱与客户端均通过明确边界接入。变更不能隐式创建第二条决策路径。
- 严格区分 Root Tool Operation、Derived Tool Operation、只读 Tool Program、Application Plan、Intent Confirmation 与实际 Host Authorization。计划/工具输出不是授权，Subagent 或能力发现不得提升权限。
- 保留用户数据、凭证与最小权限；对共享工作区、状态存储、session fork/recovery 和异步操作保持事务性与幂等性。

## 开发与证据

- 修改前确定实际受影响模块和依赖，避免把插件、Agent core、模型 dialect、UI 等无关整理混入单一 PR。
- 使用仓库已提供的 `scripts/pinned_cangjie`、`scripts/architecture_gate.sh`、`scripts/product_regression_gate.sh` 或相关聚焦测试验证变更；不要假定 SDK 版本或环境准备状态。版本、CI 和性能结果必须绑定实际提交。
- 对非确定性路径优先采用 fixture/fake provider、固定种子、可控时钟与并发调度；不可把真实网络调用或单次 smoke 当成完整验证。

## Code Review 专项不变量

- 对 Agent 执行链检查 admission → canonical tool call → authority scope → tool result → state commit → resume/fork：尤其关注跨生命周期重放、重复执行、取消竞争、恢复后丢失义务、审批绕过与错误结果传播。
- 对 capability discovery / plugin / skill / subagent 检查可发现性与权限边界分别成立：搜索结果不能直接授予工具调用权，未授权工具不得通过工具程序或嵌套调用逃逸。
- 对 provider 流式/非流式适配、重试和压缩检查状态、成本、终止原因、tool call 顺序与持久化证据，覆盖部分响应、超时、取消、重连及失败后的逆向路径。
- 安全/正确性意见需给出可到达的执行序列和可违反的不变量；不要因理论性的无限组合阻塞当前 PR。

## Code Review Rules

- 每条阻塞性意见应给出可触发输入/执行序列、违反的具体契约、影响及相关代码；不要把纯风格、未经验证的假设或已有问题的无关优化升级为阻塞缺陷。
- 对同一根因，在**一次审查**中检查相邻的正反、缺失/空值、边界、回退和对称路径；合并同一不变量的反例，而非分多轮逐个提出。只检查受影响的调用链，不穷举无关情况。
- 对照输入生产者、解码/校验者和最终使用方；确认修复同时保留合法输入与失败语义。可访问 Review Thread 时先去重，后来发现的真实回归仍必须指出。
- 后续提交重点复核当前修复、相关不变量与引入的回归；区分当前 PR 引入/加重的问题、历史缺陷和可独立跟进的建议。不得仅因审查次数多就跳过真实阻塞问题。

## Review 反馈处理与收敛

- 先验证每条 Review 意见并按根因归类；同组边界情况集中修复并补回归/参数化测试。避免“修一条、Push 一次”的循环。
- 聚合一轮实现与受影响测试后再推送；记录已修复、证据反驳、仍阻塞及范围外跟进的具体原因。
- 合并前核对最新 HEAD 上实际完成的复审与 CI；旧 SHA 的 Review、评论数归零或本地构建通过不能替代最新提交的证据。自动复审是否触发由 Codex 设置管理，`AGENTS.md` 本身不会触发 Review。
- 当前 PR 的真实阻塞缺陷与 Issue 验收必须满足；非阻塞独立改进可单开 Issue。不能用固定轮数或“全部 Thread 清零”作为唯一条件，也不应自动合并。
