# Product architecture

Axyndra 只有一份真实产品实现。产品不再以任何外部项目或隐式 sibling checkout 作为
兼容基准，本仓库的类型、协议、持久化 schema 和门禁才是行为依据。

## Canonical execution paths

```text
TUI / CLI / JSONL RPC                    embedded / headless host
          │                                      │
          ▼                                      ▼
  ApplicationSession                         AgentSdk
          │                               (AgentBuilder)
          ▼                                      │
      AgentClient                                │
          └──────────────────┬───────────────────┘
                             ▼
                    Thread Runtime Registry
                             │
                    ThreadCoordinator
                  (single semantic owner)
                             │
                         AgentCore
                 (the only model/tool loop)
                    ┌────────┼────────────┐
                    ▼        ▼            ▼
                ModelPort  ContextProjector  ToolPipeline
                    │                         │
            model_adapters            plan → policy → approval
             native HTTP              → execution → receipt
                             │
                  SQLite WAL + artifact blobs
```

`agent_product` 是可执行产品的 composition root；嵌入式调用方通过 `AgentBuilder`
提供自己的端口实现。两条入口最终都构造既有 `AgentCore` 与 `ToolPipeline`，SDK、
TUI 和 RPC 都没有第二套 Agent loop。

## Package planes

```text
dependent → dependency

agent_mcp       → agent_protocol → agent_domain
agent_extensions→ agent_mcp + tool_runtime
agent_ports     → agent_domain
tool_runtime    → agent_ports + agent_domain
agent_core      → tool_runtime + agent_ports + agent_domain
agent_sdk       → agent_core + tool_runtime + agent_ports + agent_domain
agent_runtime   → agent_domain + agent_skills
agent_store     → agent_runtime + agent_domain
run_control     → agent_core + agent_ports + agent_domain
agent_client    → run_control + agent_core + agent_domain
agent_product   → runtime packages above
agent_app       → agent_product + agent_rpc + agent_tui
agent_tui       → agent_cli + vendored cjtui packages
```

图只展示主要方向；完整 workspace 图由 `scripts/architecture_gate.sh` 从每个
`cjpm.toml` 解析并检查。门禁拒绝任意本地依赖环，拒绝 Runtime/SDK/Product
反向依赖 `agent_tui` 或 `agent_app`，并限制 TUI 只能消费窄前端边界。

## Runtime boundaries

- `agent_domain` 不依赖 JSON、文件系统、进程、网络、RPC 或终端库。核心事件使用
  `EventMeta` 与可穷举的 `AgentEventPayload`；`kind/detail` 只是适配器边界投影。
- `ModelPort.execute` 是唯一模型执行原语，只有 `agent_core` 可以调用。Provider
  的 profile/model 解析、typed API adapter、协议编码和网络错误分类属于
  `model_adapters`。协议只能由显式 `model.apiId` 选择；同协议厂商差异使用该 API
  专属 typed dialect，消息模型、流状态机、工具生命周期或 terminal/continuation
  发生结构变化时必须新增 `LlmApiAdapter`，禁止用厂商名、模型名或 URL 猜测协议。
  完整分层与判定规则见 [LLM Provider Runtime](llm-provider-runtime.md)。
- Model generation 与 Operation execution 使用独立的 durable state machine；
  provider terminal、validated Decision、atomic canonical projection 与 execution
  handoff 的边界见 [Model Attempt Runtime](model-attempt-runtime.md)。
- `NativeProviderTransport` 是生产默认传输：使用 `stdx.net.http`，逐行发送 SSE，
  每请求独立 client，按 request ID 取消（包括凭据解析阶段），并限制响应体。它不依赖
  shell 或 curl。Profile/model header 使用类型化、分层覆盖的配置，认证头始终由凭据
  边界单独拥有。
- Prompt 由 `PromptBuilder` 按稳定性、类型、信任来源、source/version 确定性排序。
  Tool Output 和 External 内容作为转义后的不可信数据块，不会被提升成系统指令。
- Thread、Context 与 Memory 是三个边界。不可变的 Turn/Item 是语义事实；Context
  是由 checkpoint、近期高保真 Items、动态状态和冻结的 ModelLane 派生的可丢弃
  projection；Memory 是跨 Thread 的显式保留、纠正、删除、冲突与检索。
- CLI 控制命令是类型化输入，不能穿透为自然语言 prompt。TUI 只消费结构化事件，
  后台任务把输入/渲染与 Provider、Tool 延迟解耦。

## Tool, MCP, and security boundaries

- Tool 执行固定经过 descriptor/catalog、参数验证、capability policy、approval、
  prepared operation、executor、receipt 和 audit。预处理与执行之间再次校验调用和
  capability 绑定，不能用 Prompt 绕过。
- 并行 Tool Call 由 Core 按 `maxConcurrentTools`、声明的并发语义和冲突关系分 wave；
  结果恢复原调用顺序，取消和部分失败仍走类型化结果。
- MCP client/server 共享 `agent_protocol` 的 JSON-RPC 2.0 值与关联规则。stdio
  使用长生命周期子进程管道，Streamable HTTP 使用 `stdx.net.http`；发现出的远端
  Tool 经 `agent_extensions` 转成普通 descriptor/executor，仍进入同一 ToolPipeline。
- Approval 只是逻辑授权，不是操作系统隔离。`sandbox_runtime` 才负责 workspace
  mount、进程/网络 namespace、资源上限、最小环境和 secret 脱敏；若 Linux、
  bubblewrap 或所需 namespace 不可用，返回 Unsupported，绝不退回裸执行。
- Workspace 路径在宿主侧规范化并限制于批准的根；环境变量默认拒绝，只允许显式
  allowlist。Secret 同时在环境投影和输出/事件边界脱敏。
- Prompt 中的 trust 标签用于组织模型输入，不是安全边界。最终权限始终由宿主的
  capability policy、approval、sandbox 和 executor 强制执行。

## State, recovery, and reliability

- 每个 Thread 的 mutable semantic state 只由一个 `ThreadCoordinator` 拥有。所有
  Model、Tool、compactor 和 child Run 结果携带 thread/turn/run/epoch/sequence，只有
  coordinator 可以把匹配的结果提交成 Item；late result 只能进入 trace。
- `ExecutionBudget`、累计 `ExecutionUsage`、deadline 与父子 `CancellationToken`
  属于 Run 控制面。Run 只有一套状态机；终态发布前必须 join 或 quarantine 所有
  owned work，取消后的外部 receipt 仍可持久化但不能越过 semantic commit fence。
- SQLite WAL 中的 Thread/Turn/Item 是 canonical transcript；Run journal 有界，
  Operation/Receipt/Approval/Audit 是独立的副作用证据。跨这些记录的状态转换使用
  单一事务，artifact body 进入 content-addressed blob store。
- `ContextReady` continuation 的 `stepOrdinal` 必须在同一事务中从 manifest 绑定的
  canonical Step 读取并校验 Thread/Lane/Turn/Run enclosure，不能由调用者复制或回退
  为零。Lane Inbox identity 包含 Thread/Lane enclosure，claim 同时校验 Run 的 durable
  Lane binding。
- execution Lane 是 `AgentRunRequest` 的显式语义 enclosure，并独立于描述模型、工具
  与能力快照的 `ModelLane`。Turn admission 在同一事务中绑定 Run、初始 Item、Step 和
  ContextManifest；crash recovery 从 `run_lane_bindings` 恢复该 Lane，禁止回退到
  `main`。
- `run_continuations` 是恢复寄存器的唯一 canonical source。schema v20 会先把旧数据库
  的 `runs.continuation` 搬入 `legacy_run_continuation_imports`，再从 canonical Run 表
  删除旧列；恢复 API 在同一事务中把一次性 import projection 封入 canonical phase
  payload 并删除 import row。两份数据不一致时以 typed RecoveryRequired fail closed。
  后续 phase 更新必须携带该 projection，Operation recovery 和 GC 只读取 canonical
  register，禁止重新引入 runtime 双读或双写。
- AppEvent 的 journal sequence 标识 canonical 事件；mailbox drain 另行分配连接内连续的
  delivery sequence。合并只影响 delivery projection，客户端 cursor 不会把合法合并误判
  为 journal 丢失。
- ContextCheckpoint 绑定 `coversThroughItemOrdinal`、source digest、projector version
  与 lane compatibility；compaction 从不修改 canonical Items，失效 checkpoint 可由
  完整 Thread 重建。
- Operation 在执行前冻结 normalized plan、能力和资源范围；Approval 绑定 exact
  digest。执行结果区分 Completed/Rejected/Cancelled/TimedOut/Failed/Unknown，Unknown
  且不可安全重试的外部效果必须进入 RecoveryRequired，而不是猜测或盲目重试。
- schema 迁移逐版本显式注册，不保留旧文件仓储的双读或 runtime 双写路径。
- Memory v3 使用追加事件保留历史，支持 scope/kind/expiry、纠正/删除、冲突解决、
  lexical 检索和可选 semantic rerank；embedding 失败时显式回退 lexical。
- `axyndra_agent_testkit` 提供只依赖 SDK 的 extension contract、确定性时钟/ID/取消；
  `agent_testkit` 仅在内部提供 scripted Provider/Tool/policy、仓储故障注入与
  P50/P95/P99 聚合。它是测试能力，不等于真实 Provider、PTY 或发布环境证明。

## Verification boundary

`scripts/architecture_gate.sh` 是快速静态门禁：它验证 workspace 依赖无环、无 UI
反向依赖、唯一 ModelPort caller、cjtui 边界和已删除过渡包。各
`support_tests/*_contract` 是聚焦的可执行行为证据。

这些证据不能替代完整 `scripts/release_gate.sh`。聚焦 contract 通过，不代表真实
Provider、打包产物、入口黑盒、真实 PTY、长时间性能/内存或目标平台已验证。详细
能力矩阵见 [runtime-capabilities.md](runtime-capabilities.md)。
