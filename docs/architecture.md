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
agent_sdk       → yjson + yjson_support
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
完整依赖 pin、native/link 和 stdx 传递闭包见 [依赖与 stdx 审计](dependencies.md)；候选切换合同见
[stdx 迁移执行规格](stdx-migration.md)。

## Runtime boundaries

- `agent_domain` 使用 `yjson`/`yjson_support` 表示 `AgentValue` 和 JSON 协议值，
  并通过 `process4cj` 类型参与取消适配；它不拥有文件、网络、RPC 或终端 I/O。
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
- Approval 只是逻辑授权，不是操作系统隔离。`agent_product` 通过
  `sandbox4cj` 负责 workspace mount、进程/网络 namespace、资源上限、最小环境
  和 secret 脱敏；若 Linux、bubblewrap 或所需 namespace 不可用，返回
  Unsupported，绝不退回裸执行。workspace 外的 `sandbox_runtime` 是独立实验包。
- Workspace 路径在宿主侧规范化并限制于批准的根；环境变量默认拒绝，只允许显式
  allowlist。Secret 同时在环境投影和输出/事件边界脱敏。
- Prompt 中的 trust 标签用于组织模型输入，不是安全边界。最终权限始终由宿主的
  capability policy、approval、sandbox 和 executor 强制执行。

## E0-01 state ownership

本节是基于候选基线 `6eb992ad51c21a5205cabee007306b523217a214` 的状态归属审计，
不是新的运行时契约。切分依据是语义 owner、持久化事务和副作用 handoff，而不是
文件大小或 package 数量；`→` 表示当前源码中的主要调用关系。

| 边界 | Owner 与源码入口 | 调用关系与事务范围 | Split risk | 回归锚点 | 本次验证状态 |
| --- | --- | --- | --- | --- | --- |
| Model request / Attempt / retry | `agent_core/src/core.cj` 的 `continueRun`、`buildBoundedModelRequest`、`executeCanonicalModelTurn`、`executeModelWithTurnRetry`、`persistModelAttemptBeforeRequest`、`claimModelAttemptBeforeRequest`；`persistence_runtime/src/sqlite_run_repository.cj`；`agent_core/src/model_control.cj` 的 `ControlledModelPort.execute` | `continueRun → executeCanonicalModelTurn → executeModelWithTurnRetry → Attempt policy/claim → ControlledModelPort.execute`。Attempt policy 和 restart boundary 各自在 Run repository 的 SQLite transaction 内完成；provider adapter 只执行一次 wire call。 | 把 retry/Attempt owner 放进 provider 会重复计费、破坏 replay identity，或让未接受的 reply 进入 transcript。 | `deadlineRetryExactReplayContract`、`modelResumeCrashWindowMatrixContract`、`failedAttemptDoesNotPolluteTranscriptContract`、`partialToolCallNeverEscapesContract` | **已有且本次验证**：`vnext-contracts` 通过。 |
| Canonical semantics / Decision projection | `agent_core/src/core.cj` 的 `commitCanonicalModelDecision`；`agent_runtime/src/thread_runtime.cj` 的 `AgentThreadRuntime`；`agent_runtime/src/thread_coordinator.cj` 的 `ThreadCoordinator`；`agent_store/src/thread_commit_sink.cj`；`agent_runtime/src/model_decision_port.cj` | 已验证的 `ModelDecision` 先由 `ThreadCoordinator.commitBatch` 投影为 canonical Items，再由 `ModelDecisionRuntimePort.recordCanonicalProjection` 记录绑定；Thread sink、Decision store 各有明确 SQLite transaction，不能假设跨 repository 原子。 | 让 worker、provider 或 projection 直接持有 Thread store 会制造第二语义 owner、半个 Decision batch 或过期 run/epoch 结果。 | `canonicalCommitContract`、`modelResultBatchContract`、`schedulerPermutationContract`、`settlementReentryContract`、`rejectedSettlementContract` | **已有且本次验证**：`thread_runtime_contract`、`thread_runtime_integration_contract`、`product_thread_runtime_contract` 通过。 |
| Execution / approval / tool batch | `agent_core/src/tool_batch.cj` 的 `CoreToolBatchCoordinator`；`tool_runtime/src/tools.cj` 的 `prepareCommitted`、`authorize`、`executePrepared`；`agent_store/src/operation_runtime_store.cj` | `CommittedToolCallRef → prepareCommitted → authorize/decide → executePrepared`。批协调器在第一个 approval barrier 停止后续准备；Operation 的 prepare、approval、executing、handoff 是分段事务，executor 不能在 prepared 或 approval 阶段被调用。 | 用 raw `ToolCall` 或 UI 状态代替 canonical ref/normalized plan 会允许未提交调用、旧 capability 或漂移 descriptor 进入副作用。 | `approvalBatchBarrierContract`、`toolContextApprovalResumeContract`、`partialToolWaveFailureContract`、`partialWaveHandoffFailureContract` | **已有且本次验证**：`agent_core_contract`、`tool_runtime_contract` 通过。 |
| Budgets / Run control | `agent_core/src/runtime_control.cj` 的 `CoreRunControl`、`BudgetCounter`；`run_control` / `agent_domain/src/v3_control.cj` 的 `ExecutionBudget`、`RunState`、`BudgetMode` | CoreRunControl 持有 cancellation source、active IDs 和 ledger；请求、turn、token/cost、drain charge 通过同一 Run accounting 更新。Draining 是显式状态/预算分支，不是重新填充默认 headroom。 | 重建局部 counter、把 drain 当普通 work、或让 child 预算绕过父 ledger 会导致超额执行和终态前 work debt。 | `workCannotUseDrainHeadroomContract`、`drainPreflightBlocksNearCostBoundaryContract`、`resumeDrainPreservesSeparateRequestBucketsContract`、`failedAttemptUsageObeysRequestBudgetContract`、`childBudgetPoolSettlesWorkPlusDrainContract` | **已有且本次验证**：`agent_core_contract` 通过。 |
| Completion / cancel / join / quarantine | `agent_runtime/src/run_lifecycle.cj` 的 `RunLifecycle`；`agent_runtime/src/thread_runtime.cj` 的 settling/terminal path | `RunLifecycle` 维护 child ownership，进入 joining 后拒绝新 child，join 后将不能安全加入的 work quarantine；Thread runtime 解锁等待 join，随后通过 Thread sink 提交 terminal transition。join 与 SQLite commit 不共享跨边界 transaction。 | 把 cancellation 当即时终态、在 join 前发布 terminal，或让 late result 重新打开 Thread 会留下 dangling child 和不可解释的 receipt。 | `structuredCancellationContract`、`quarantineContract`、`settlementReentryContract`、`rejectedSettlementContract` | **已有且本次验证**：`run_lifecycle_vnext_contract`、`thread_runtime_contract` 通过。 |
| Persistence transaction boundaries | `persistence_runtime/src/sqlite_run_repository.cj`；`agent_store/src/thread_commit_sink.cj`；`agent_store/src/operation_commit.cj`；`agent_store/src/operation_runtime_store.cj` | Attempt policy/restart、Thread transition、operation-result receipt/item/run/thread projection 分别在各自 sink/repository transaction 内完成；`AgentStore.commitOperationResult` 能在一个 SQLite transaction 中联合写 operation receipt、operation state、ToolResult Item、Run 和 Thread revision。model call、内存预算、executor 外部副作用、task snapshot 不在同一跨组件 transaction。 | 把“一个 SQLite transaction”误写成“整个 product operation 原子”会掩盖 handoff 后崩溃、外部副作用与 transcript/task snapshot 的恢复窗口。 | `attemptPolicyAtomicityContract`、`retryAttemptAtomicityContract`、`restartAttemptAtomicityContract`、`continuationCasIdempotencyContract`、`durableCommitRollbackContract`、`repeatedCrashRecoveryContract` | **已有且本次验证**：`sqlite_run_repository_contract`、`agent_store_contract`、`chaos_contract` 通过；真实 product restart replay 仍未单独验证。 |
| Product composition / Skills / process / eval / extensions | `agent_product/src/product.cj` 的 `ProductRuntime`；`agent_product/src/skill_runtime.cj` 的 `ProductSkillRuntime`；`agent_product/src/local_infrastructure.cj` 的 `LocalProcessPort`；`agent_extension_runtime/src/runtime.cj` / `safe_lifecycle.cj` | Composition root 组装唯一 AgentCore、Thread registry、ToolPipeline、stores 与 process port；Skill snapshot 在 admission 时冻结；process/eval 属于 product resource owner；compiled extension runtime 负责 discovery/validation/activation lifecycle，不拥有 Thread semantics。 | 把 skill discovery、process/eval kernel 或 extension lifecycle 直接变成 semantic commit owner，会绕过 Run/Operation/approval boundary；动态 package/JS host 仍不应从当前 lifecycle 代码推断为已交付。 | `product_prompt_contract`、`product_contract`、`skill_runtime_vnext_contract`、`extensions_contract` | **已有且本次验证**：product skill fixture 与 product build 通过；compiled-extension/eval 的完整宿主矩阵未运行。 |
| Durable handoff / external effect / result replay | `tool_runtime/src/tools.cj` 的 `executePrepared`；`agent_store/src/operation_runtime_store.cj` 的 `markExecuting` / `markExecutionHandoff`；`agent_store/src/operation_commit.cj` | `loadPlan/loadCommittedToolResult → current descriptor/capability recheck → markExecuting → markExecutionHandoff → afterHandoff → executor → commitOperationResult`。handoff 是 executor 前最后一个 durable marker；已有 committed result 直接 replay，未确认外部结果不能猜测为 success。 | 在 handoff 前后重新 resolve raw invocation，或把 Unknown 当可安全 retry，会重复外部 effect；把 receipt 与 semantic Item 拆成无 owner 的独立写也会污染 transcript。 | `operation_domain_vnext_contract`、`agent_store_contract`、`chaos_contract`、`tool_runtime_contract` | **已有且本次验证**：prepared-only、receipt 与 crash-state contracts 通过；真实外部 effect replay 未运行。 |
| Program suboperations | `agent_product/src/vnext_control.cj` 的 `ProductProgramSubOperationExecutor`；`tool_runtime` 的 `ToolProgram` / `prepareProgramSubOperation` | Program suboperation 重新使用 `ToolPipeline.prepare`、canonical ToolCall Item、`operations.prepareProgramSubOperation` 和 `executePrepared`，结果回到同一 Operation/Thread runtime；当前 `ToolProgram` 的并行调度仍是顺序执行。 | 把 program suboperation 当可信 raw shortcut 会破坏 parent Operation identity、预算和 receipt linkage；把并行语义提前宣称为真实并发会误导 capacity/ordering。 | `product_contract`、`task_persistence_contract`、`operation_domain_vnext_contract` | **已有但未验证**：本轮 focused baseline 未单独运行 program-suboperation scenario。后续归入 E1。 |
| Managed async job / final message settlement | `agent_product/src/task_product.cj` 的 `ProductAsyncJobState` / `startBashJob`；`agent_product/src/task_persistence.cj`；`agent_product/src/product.cj` 的 `appendExternalMessageOnce` | worker 捕获 `PreparedToolInvocation` 和 `operationId`，不重新 resolve raw call；task snapshot、process outcome、external message、receipt/ack 是不同持久化步骤，最终消息使用 once-only delivery identity。 | 把 async worker 当第二 executor/semantic owner，或声称 task snapshot、外部 effect、Thread message 同一 transaction，会掩盖 process crash、late settlement 和 duplicate delivery 窗口。 | `task_persistence_contract`、`product_contract`、`rpc` frontend regression | **已有但未验证**：当前源码有 handoff/settlement path，但 E3/E4 的 crash/replay/PTY matrix 尚未运行。 |

### E0-01 responsibility seams

候选责任 seam 只在上表所列的 invariant 交界处成立：

- **Model semantic owner**：`AgentCore` 编排 request/Attempt/retry；`SqliteRunRepository`
  与 `SqliteModelDecisionStore` 负责对应 durable evidence；provider adapter 只负责
  一次 wire execution 和 terminal evidence。
- **Thread semantic owner**：`AgentThreadRuntime` 对外拥有 live Thread，
  `ThreadCoordinator` 串行化 semantic transition，`SqliteThreadCommitSink` 负责 durable
  commit。worker 只能返回带 enclosure 的结果 envelope。
- **Execution owner**：`ToolPipeline` 只接受 canonical committed call 进入 production
  path；`DurableOperationStore`/`AgentStore` 持有 operation state、handoff 与 receipt。
- **Run/budget owner**：`CoreRunControl` 和 `RunLifecycle` 分别维护 Run admission、
  cancellation、budget ledger 与 async ownership；不再引入第二套局部状态机。
- **Product composition owner**：`ProductRuntime` 组装依赖；Skill、process/eval、
  extension lifecycle 是资源/生命周期边界，不得成为 Thread semantic owner。

这些 seam 是 E0-01 的审计结论，不是本次的代码重构计划；E0-02 才会把缺口收敛成
带具体 contract 的执行项。当前唯一需要特别保留的限制是：单个 SQLite sink transaction
可以联合提交一组相关事实，但不能把 model provider、内存 ledger、外部 process effect、
async task snapshot 和所有 repository 调用扩大成一个不存在的全局原子操作。

## State, recovery, and reliability

- 每个 Thread 的 mutable semantic state 只由一个 `ThreadCoordinator` 拥有。所有
  Model、Tool、compactor 和 child Run 结果携带 thread/turn/run/epoch/sequence，只有
  coordinator 可以把匹配的结果提交成 Item；late result 只能进入 trace。
- `ExecutionBudget`、累计 `ExecutionUsage`、deadline 与父子 `CancellationToken`
  属于 Run 控制面。Run 只有一套状态机；终态发布前必须 join 或 quarantine 所有
  owned work，取消后的外部 receipt 仍可持久化但不能越过 semantic commit fence。
- SQLite WAL 中的 Thread/Turn/Item 是 canonical transcript；Run journal 有界，
  Operation/Receipt/Approval/Audit 是独立的副作用证据。各 repository/sink 在自己的
  SQLite transaction 内维护这些记录；特定的 operation-result projection 可以在一个
  sink transaction 中联合写 receipt、Operation、ToolResult、Run 和 Thread revision，
  但 model call、内存预算、外部 process effect、async task snapshot 和跨 repository
  调用不共享一个全局原子事务。artifact body 进入 content-addressed blob store。
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
- 新写入的 phase projection 使用 `run-request-snapshot-v1`：完整请求以结构化
  `AgentValue` 保存，并附带独立 SHA-256 摘要；读取时必须先验证摘要，再重建
  `RunContinuation` 兼容投影。旧 `legacy-continuation-v4` 字符串仅允许存在于 migration
  bridge，首次 import/write 会升级为结构化 snapshot，其他生产包不得解析或生成它。
- schema v21 在 `run_continuations.active_attempt_id` 中保存 nullable、带外键的当前 Model
  Attempt binding。terminal cleanup 在同一 writer transaction 中校验该索引后删除寄存器，
  不再为清理动作反序列化完整请求快照；旧 v20 行没有索引时仍使用严格 canonical decode。
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
