# Runtime capability matrix

本页描述当前真实产品中已经存在的能力、强制边界和证据入口。状态中的“有契约”
只表示相应聚焦 contract 覆盖公共行为；它不是发布证明，也不代表所有平台都可用。

| 能力 | 实现位置 | 当前边界 | 聚焦证据 |
| --- | --- | --- | --- |
| Provider-neutral 模型协议 | `agent_domain`, `agent_ports`, `model_adapters` | Runtime 不接触 Provider JSON；capability 在网络调用前校验 | `model_adapters_contract`, `v3_domain_contract` |
| Unified LLM runtime | `model_adapters/src/unified_runtime.cj`, `agent_product` | Provider Profile、Model、Wire API 与 API-scoped typed dialect 正交组合；协议由 `model.apiId` 显式选择；字段/能力/replay 差异复用 adapter，消息、流、工具或 terminal 状态机结构变化必须新增 adapter；未知 API 或错误 dialect 在 I/O 前 fail-closed | `model_adapters_contract`, `product_contract` |
| Provider auth、headers 与 usage 证据 | `agent_product`, `model_adapters`, `agent_domain`, `agent_store` | profile/model/request header 按类型化优先级合并且认证头保留；取消覆盖凭据解析与网络；usage 记录 final/stream-final 来源及 terminal evidence 并向后兼容持久化 | `model_adapters_contract`, `product_contract`, `agent_domain_contract`, `agent_store_contract` |
| Output-limited recovery | `agent_core`, `agent_domain` | 未形成 accepted Decision 时创建有界 child Attempt，持久化降低后的 recovery ceiling；截断工具块不进入 canonical Decision 或执行 | `agent_core_contract`, `agent_domain_contract`, `model_adapters_contract` |
| 图像、结构化输出与缓存 | `agent_domain`, `model_adapters`, `agent_core`, `agent_sdk` | typed Image/Schema/Result；宿主二次 schema 校验；StablePrefix 映射 Provider 缓存参数；能力或 cache key 缺失时请求前失败 | `model_adapters_contract`, `sdk_contract`, `v3_domain_contract` |
| 原生 HTTP 与 SSE | `model_adapters/src/native_transport.cj` | `stdx.net.http`、每请求独立 client、request-ID cancel、64 MiB 响应上限；生产默认不依赖 curl | `model_adapters_contract` |
| 类型化事件与状态机 | `agent_domain/src/v3_control.cj`, `agent_core/src/runtime_control.cj` | 强 ID 关联、合法状态转换、父子取消、deadline、累计预算 | `v3_domain_contract`, `agent_core_contract` |
| Prompt 与 Project Context | `agent_core/src/prompt_v3.cj` | 确定性 stable prefix；不可信外部/工具内容被分隔和转义；预加载有文件/字节预算 | `prompt_memory_v3_contract` |
| Context 与 Compaction | `agent_core/src/context.cj`, `agent_product` | token 高/低水位；切点保持 tool-call/result 边界；请求窗口不删除 Session 事实 | `agent_core_contract`, `product_contract` |
| Tool descriptor/pipeline | `tool_runtime` | catalog → validation → policy → approval → prepared execution → receipt/audit | `tool_runtime_contract` |
| ToolContext / 依赖注入 | `tool_runtime/src/context.cj`, `agent_core`, `agent_product`, `agent_sdk` | workspace/cwd、显式过滤环境、typed service 描述均为不可变快照；活动 CancellationToken 由 Core 按 run 绑定 | `tool_runtime_contract`, `agent_core_contract`, `sdk_contract`, `product_contract` |
| 并行 Tool Call | `agent_core/src/tool_batch.cj` | 按并发声明和冲突关系分 wave；有界并发、稳定结果顺序、协作取消 | `agent_core_contract`, `tool_runtime_contract` |
| Workspace Sandbox | `agent_product`, `sandbox4cj` | bubblewrap namespace、mount、resource limit、最小环境；宿主不支持时 fail-closed；`sandbox_runtime` 是 workspace 外的独立实验包 | `sandbox_contract` |
| Secret 与环境边界 | `agent_product`, `sandbox4cj` | 环境默认拒绝、显式 allowlist、启发式 secret 名和已知值脱敏；`sandbox_runtime` 不属于根产品构建 | `sandbox_contract`, `product_contract` |
| Canonical Thread state | `agent_domain`, `agent_runtime`, `agent_store` | Thread/Turn/Item 是唯一语义事实；每个 Thread 单 owner，异步结果携带 run/epoch 后才可提交 | `thread_runtime_contract`, `agent_store_contract`, `chaos_contract` |
| Context projection/checkpoint | `agent_runtime`, `agent_store`, `agent_core` | ModelContext 从 canonical Items 派生；checkpoint 覆盖不可变前缀且不改写 Thread | `context_projector_vnext_contract`, `agent_store_contract` |
| SQLite WAL durability | `agent_store`, `persistence_runtime` | Thread、Run、Operation、Receipt、Approval、metadata 与 memory 使用一个事务数据库；artifact body 单独内容寻址，归档同时快照 DB 与 blobs | `agent_store_contract`, `sqlite_run_repository_contract`, `gc_contract`, `product_contract` |
| Long-term Memory v3 | `persistence_runtime/src/memory_v3.cj` | scope/kind/expiry、纠正/删除/冲突、lexical + 可选 semantic；embedding 失败回退 | `prompt_memory_v3_contract` |
| JSON-RPC 2.0 | `agent_protocol` | typed request/response/notification、ID correlation、frame/value limits | `mcp_contract`, `product_rpc_contract` |
| MCP Client/Server | `agent_mcp` | 2026-07-28 元数据、发现/分页/调用/取消/lifecycle；stdio 与 Streamable HTTP 原生 transport | `mcp_contract` |
| MCP Tool bridge | `agent_extensions/src/mcp_extension.cj` | alias 后成为普通 Tool；不能绕过 ToolPipeline 权限和 receipt | `mcp_extension_contract` |
| MCP product composition | `agent_product/src/mcp_runtime.cj` | `mcp.yml` 启动/发现/注册/关闭；stdio 强制只读工作区、进程隔离、普通 `env` allowlist、独立 `secret_env` grant/脱敏和默认禁网，隔离不可用时 fail-closed | `mcp_product_contract` |
| MCP product server | `agent_product/src/product_mcp_server.cj`, `agent_app/src/mcp_server_cli.cj` | `axyndra mcp-server` 与嵌入式 builder 暴露同一 Tool catalog；Host policy/approval 仍权威，input-required/approval 不能伪装成功 | `product_mcp_server_contract` |
| Embeddable SDK | `agent_sdk` | `AgentBuilder` 显式注入 Provider/Store/Policy/Budget；复用唯一 AgentCore | `sdk_contract` |
| Headless/JSONL | `agent_embed/src/headless.cj`, `agent_app` | typed exit status、UTF-8 JSONL、可插入 redactor、审批 continuation/cancel | `sdk_contract`, `artifact_contract` |
| Public SDK testkit | `axyndra_agent_testkit` | deterministic clock/ID/cancellation、pure extension contract harness、experimental named fault plan；JSON 值由 yjson 提供 | `testkit_consumer`, `testkit_extension_contract` |
| Internal Agent testkit | `agent_testkit` | scripted Model/Tool/policy、Run/Operation port doubles、audit recorder、benchmark 分位数；仅内部测试依赖 | `testkit_contract`, `chaos_contract`, `extensions_contract` |
| Coding Agent tools | `agent_product` | read/search/edit/shell 受 workspace、approval、operation receipt 与 audit 约束 | `product_contract`, `worktree_contract` |
| Planning/Subagent/Task | `agent_core`, `agent_runtime`, `task_runtime`, `run_control` | 子任务仍使用 AgentCore；权限、取消和预算不因委派消失；`subagent_runtime` 目前只是 workspace 外的说明占位 | `orchestration_contract`, `task_persistence_contract` |
| TUI / RPC / CLI | `agent_tui`, `agent_rpc`, `agent_cli`, `agent_app` | UI 不依赖 Core/持久化；命令不伪装成 Prompt；所有入口消费同一 Runtime | `agent_cli_contract`, `client_contract`, `product_rpc_contract` |

## Roadmap baseline (E0-01)

下表把 #36 E0-01 的“已有实现”“未验证边界”和“明确缺口”分开记录。状态短语只
描述当前证据，不等于把后续 issue 勾选完成；命令均在候选 commit
`6eb992ad51c21a5205cabee007306b523217a214`、tree
`db5a4edb67563d9c0a0acf4a83ca2db633d5ed7e` 上执行。

| #36/关联 Issue | 当前源码入口 | 已实现边界 | 明确缺口或限制 | 现有回归入口 | 本次命令/结果/耗时 | 未运行项 | 后续任务 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| E0-01 / ordinary model + Attempt | `agent_core/src/core.cj`：`continueRun`、`executeCanonicalModelTurn`、`executeModelWithTurnRetry`；`persistence_runtime/src/sqlite_run_repository.cj`；`agent_core/src/model_control.cj` | **已有且本次验证**：Attempt 在 provider wire call 前持久化/claim；retry identity、terminal Decision 和 failed-attempt transcript boundary 由 Core/Run repository 维护。 | 不包含真实 Provider smoke；provider 认证、协议差异和外部服务状态不由本次本地基线证明。 | `agent_core_contract`、`model_adapters_contract`、`sqlite_run_repository_contract` | `python3 scripts/vnext_contract_gate.py --sdk-root "$HOME/cangjie_sdk/sts1.1.3"`：PASS，17 个 focused contracts，738.147s 单样本（summary 总计 738.085s）。 | `provider_real_smoke`、长时间/多 provider replay、release gate。 | E0-02：把剩余语义/恢复缺口收敛成 contract。 |
| E0-01 / canonical Thread + Decision | `agent_runtime/src/thread_runtime.cj`、`thread_coordinator.cj`；`agent_core/src/core.cj`：`commitCanonicalModelDecision`；`agent_store/src/thread_commit_sink.cj`；`agent_runtime/src/model_decision_port.cj` | **已有且本次验证**：单一 Thread semantic owner；validated Decision 才能批量投影 Items；结果带 thread/turn/run/epoch/sequence enclosure。 | Decision store projection 与 Thread sink 是明确但不同的 transaction；不能宣传为跨 repository 全局原子提交。 | `thread_runtime_contract`、`thread_runtime_integration_contract`、`product_thread_runtime_contract`、`agent_store_contract` | 同一 `vnext_contract_gate`：上述 contract 均 PASS；architecture gate 1.858s。 | 多进程共享 writer、真实 restart 后 product Decision replay、全量 release matrix。 | E0-02 / E0-04：补 canonical projection 与 recovery proof。 |
| E0-01 / prepared-only execution + approval | `tool_runtime/src/tools.cj`：`prepareCommitted`、`loadPreparedForApproval`、`authorize`、`executePrepared`；`agent_core/src/tool_batch.cj` | **已有且本次验证**：生产 Core 只能从 `CommittedToolCallRef` 准备；normalized plan、descriptor、capability 在 handoff 前复核；approval barrier 停止后续 batch preparation。 | raw SDK `prepare` 是 plan-only；本地 contract 使用 in-memory operation doubles，不能等同于 SQLite restart replay。 | `tool_runtime_contract`、`agent_core_contract`、`operation_domain_vnext_contract` | `vnext_contract_gate`：PASS，738.147s；ACP cancel/resume fixture：PASS，0.709s。 | 真实 UI approval、多进程 approval resume、外部 effect replay。 | E0-02 / E0-05：补 handoff/recovery matrix。 |
| E0-01 / single Operation + Receipt | `agent_store/src/operation_runtime_store.cj`、`operation_commit.cj`；`tool_runtime/src/tools.cj` | **已有且本次验证**：Operation plan、execution handoff、receipt 和 canonical ToolResult 有持久化 owner；`AgentStore.commitOperationResult` 可在一个 SQLite transaction 联合写 receipt/operation/item/run/thread。 | handoff 后外部 effect 不与 task snapshot、model call 或所有 repository 调用共享全局事务；Unknown 必须进入 recovery path，不能猜测成功。 | `agent_store_contract`、`chaos_contract`、`operation_domain_vnext_contract` | `vnext_contract_gate`：PASS；RPC bash-abort fixture：PASS，1.622s。 | 真实 shell/process effect 的崩溃窗口、跨进程 receipt replay、release artifact recovery。 | E0-04 / E0-05 / E3：外部 effect 与 durable handoff proof。 |
| E0-01 / budgets + Draining | `agent_core/src/runtime_control.cj` 的 `CoreRunControl` / `BudgetCounter`；`agent_domain/src/v3_control.cj`；`run_control` | **已有且本次验证**：work、drain、turn、token/cost 使用同一 Run accounting；失败 attempt usage 也遵守 request budget；child pool 在 settlement 前结算 work + drain。 | 本轮没有性能/资源压力基线；P50/P95/P99 仅是 collector 的单样本统计，不是性能承诺。 | `agent_core_contract`、`child_run_vnext_contract` | `vnext_contract_gate`：PASS，738.147s；collector 的所有 benchmark 都是 `samples=1,warmups=0`。 | soak、并发压力、跨平台 quota、真实 provider cost/latency。 | E0-04：预算、join、quarantine 的统一 proof。 |
| E0-01 / cancellation + recovery | `agent_runtime/src/run_lifecycle.cj`；`agent_runtime/src/thread_runtime.cj`；`agent_product/src/task_product.cj` | **已有且本次验证**：join 前拒绝新 child；不能安全加入的 work quarantine；settling/terminal transition 有 Thread owner；ACP/RPC fixture 覆盖 abort 后继续请求。 | focused gate 排除真实 PTY/TUI；async task 的 process crash、late settlement 与 task snapshot 交叉恢复未完成矩阵。 | `run_lifecycle_vnext_contract`、`thread_runtime_contract`、`chaos_contract`、frontend regression `acp`/`rpc` | `vnext_contract_gate`：PASS，738.147s；ACP PASS 0.709s；RPC PASS 1.622s。 | `pty_and_tui_gates`、真实 provider timeout、长生命周期 worker crash。 | E0-04 / E3 / E4：cancellation、async settlement、TUI proof。 |
| E0-01 / product composition | `agent_product/src/product.cj`：`ProductRuntime`；`agent_product/src/skill_runtime.cj`；`agent_product/src/local_infrastructure.cj`：`LocalProcessPort` | **已有且本次验证**：产品 composition root 组装唯一 AgentCore/Thread registry/ToolPipeline/stores；Skill snapshot、process port 和 sandbox policy 有明确 owner。 | compiled extension lifecycle、eval kernel、installed package layout 和真实 sandbox capability 未由本轮 product build 单独证明。 | `product_prompt_contract`、`product_thread_runtime_contract`、`product_contract` | Product skill fixture：PASS，65.379s；`scripts/pinned_cangjie` cjpm build -m agent_app -o agent_app：PASS，74.656s。 | installed/release package、真实 provider、sandbox namespace、extension/eval host matrix。 | E0-06 / E1 / E3：按 product boundary 补验证。 |
| #29 / Skills（已关闭） | `agent_product/src/skill_runtime.cj`：`ProductSkillRuntime`；`support_tests/product_prompt_contract` | **已有且本次验证**：metadata-only bounded header、automatic discovery/run、explicit snapshot、lazy refs、next-run rediscovery、invalid UTF-8 metadata 行为均在 fixture 中覆盖。 | fixture 证明的是确定性本地 roots；未证明安装目录、跨用户目录和发布包中的 skill inventory。 | `product_prompt_contract`、`skill_runtime_vnext_contract` | `support_tests/product_prompt_contract` 的 build + executable：PASS，`product prompt contract passed`，65.379s。 | installed artifact discovery、real-world skill corpus、release layout。 | 无新的 #29 实现项；产品集成缺口随 E0-06 处理。 |
| #31 / toolchain policy（已关闭） | `scripts/check_sdk.sh`、`scripts/sdk_paths.sh`、`scripts/check_native_compiler.sh`、`scripts/check_sdk_test.py` | **已有且本次验证**：STS SDK selection/exact version policy、minimum-version comparison、prerelease rejection/acceptance cases 和 native Clang gate 可执行；本次选中 Cangjie 1.1.3、Clang 22.1.8。 | 本次没有运行 nightly/newer SDK matrix、其他平台 SDK 或完整 release packaging。 | `check_sdk_test.py`、`architecture_gate.sh`、`scripts/check_native_compiler.sh` | `python3 scripts/check_sdk_test.py`：PASS，0.192s；`AXYNDRA_REQUIRE_EXACT_TOOLCHAIN=1 scripts/check_sdk.sh`：选中 `$HOME/cangjie_sdk/sts1.1.3`，1.10s；`cjc/cjpm --version` 均 1.1.3。 | nightly/next SDK、Windows/macOS/Android/OHOS、CI image matrix。 | 无新的 #31 实现项；future SDK compatibility 属于独立验证。 |
| #34 / #35 / compiled extensions + eval | `agent_extension_runtime/src/runtime.cj`、`safe_lifecycle.cj`；`agent_product/src/local_infrastructure.cj` 的 `LocalProcessPort` | **已有但未验证**：compiled extension discovery/validation/activation/deactivation lifecycle 与 product eval/process owner 已有源码入口。 | **明确缺口**：本轮没有证明 dynamic package loading、JS host、extension generation reload 与 eval kernel 的 end-to-end product contract；不能把 lifecycle 类型或编译通过写成 #34/#35 已交付。 | `extensions_contract`（源码入口）、`product_contract`、architecture/package gates | `bash scripts/architecture_gate.sh`：PASS，1.858s；product build PASS 74.656s；均不替代 dedicated extension/eval runtime proof。 | extension activation/reload matrix、JS/eval host、dependency resolver、network/process policy、installed plugin package。 | #35 contract 先于 #34 implementation；由 roadmap 依赖图排入后续阶段。 |
| #36 / later E1–E4, P/R | `agent_product/src/vnext_control.cj` 的 `ProductProgramSubOperationExecutor`；`agent_product/src/task_product.cj` 的 `ProductAsyncJobState` / `startBashJob`；`agent_tui` / `agent_app` 入口 | **已有但未验证**：Program suboperation、async job settlement、TUI/RPC product paths 在当前源码中可定位；worker 捕获 prepared invocation，不重新 resolve raw call。 | **明确缺口**：E1–E4/P/R 的 acceptance matrix、真实 PTY key sequence、delayed SSE boundary、restart/replay/receipt proof 尚未完成；本行不替代后续 issue 勾选。 | `product_contract`、`task_persistence_contract`、frontend regression `acp`/`rpc`、`vnext` focused gate | 本次仅证明 related focused contracts/builds：vnext PASS 738.147s、ACP PASS 0.709s、RPC PASS 1.622s；没有声明 later issue 完成。 | `pty_and_tui_gates`、full release gate、real provider smoke、program-suboperation direct scenario、async crash/replay matrix。 | 依赖图下一项：E0-02；之后按 E1 → E2/E3/E4/P/R 重新计算。 |

### Evidence record

- Environment: Linux/x86_64; selected STS Cangjie SDK `$HOME/cangjie_sdk/sts1.1.3`；`cjc`
  与 `cjpm` 为 1.1.3；native compiler 为 Clang 22.1.8。
- Baseline: candidate commit `6eb992ad51c21a5205cabee007306b523217a214`，tree
  `db5a4edb67563d9c0a0acf4a83ca2db633d5ed7e`。
- Commands were run with one warm sample and zero warmups by the baseline collector. The
  uncommitted evidence directory is represented as `$AXYNDRA_EVIDENCE_DIR`; its sealed
  `gate-manifest.json` records status `passed`, the selected SDK, the focused-contract
  summary, and the `target/release/bin/agent_app` artifact digest. It is not a repository
  artifact.
- `vnext_contract_gate.py` explicitly excludes `provider_real_smoke`, `pty_and_tui_gates`,
  `package_readiness`, and `full_release_gate`; those exclusions remain open evidence gaps.
- PR CI is pending until the E0-01 audit commit is published; the final revision of this
  page will record the actual PR check URL and conclusion rather than infer CI from local
  commands.

## Security invariants

以下不变量是实现边界，而不是 Prompt 建议：

1. 模型只能提出 Tool Call，不能直接执行宿主操作。
2. Tool 在执行前必须经过参数验证、capability policy 和 approval；执行后必须产生
   receipt/audit，恢复时按副作用与幂等语义处理。
3. MCP、Extension、SDK 和 Subagent 只能贡献或组合能力，不能获得绕过 ToolPipeline
   的快捷路径。
4. Approval 不等于 Sandbox。真正的文件、进程、网络、环境和资源隔离由宿主执行；
   隔离不可用时必须失败，不能静默降级。
5. System/User/Project/Tool/External 是信任来源标签；外部文字即使看起来像指令也
   不能改变 Host Policy。
6. 配置描述不能回显 secret；凭据只在 Provider/Transport 边界读取。任何会进入
   Session、日志或 JSONL 的外部/Tool 文本都必须先经过宿主配置的 redactor。

## Evidence levels

| 层级 | 能说明什么 | 不能说明什么 |
| --- | --- | --- |
| `scripts/architecture_gate.sh` | 静态依赖方向、唯一核心调用点和前端边界 | 编译、运行时行为、平台能力 |
| 单个 `support_tests/*_contract` | 某个公共行为在选定 SDK/主机上的确定性结果 | 整仓集成、真实 API、发行包 |
| implementation gate | 整仓构建、契约、打包与本地黑盒的组合证据 | 未运行的真实 Provider smoke 和其他平台 |
| release gate | 当次命令实际列出的全部发布检查 | 未包含的操作系统、长期 soak 或供应商状态 |

任何报告都应记录具体命令、SDK、主机条件和未运行项。尤其是：Sandbox contract
验证 fail-closed 语义，不保证当前宿主允许创建 network namespace；benchmark
聚合器可计算 P50/P95/P99，不等于已经取得稳定的真实 PTY 性能基线。

## Native runtime path

开发树不是独立发行布局。直接执行 `target/release/bin/agent_app` 不属于受支持的
开发入口；应通过 `scripts/pinned_cangjie` 启动，以准备并显式注入当前工作区的
`libprocess4cj_native.so`。`scripts/package_candidate.sh` 是可迁移发行布局的唯一
生成入口：它复制非系统依赖，为主程序设置 `$ORIGIN/../lib`、为包内库设置
`$ORIGIN`，并在清除 `LD_LIBRARY_PATH` 后运行 `ldd`，发现 `not found` 即失败。
这一区分是显式的 wrapper-only development invariant 与 relative-RPATH package
invariant，不允许使用主机绝对 RPATH 或全局 `LD_LIBRARY_PATH` workaround。
