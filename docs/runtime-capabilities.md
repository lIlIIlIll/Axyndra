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
| Portable plugin packages | `agent_extension_runtime/src/plugin_package.cj`, `agent_extension_runtime/src/javascript_host.cj`, `agent_product/src/product.cj`, `agent_product/src/plugin_runtime.cj`, `agent_product/src/plugin_acquisition.cj`, `agent_product/src/skill_runtime.cj`, `agent_product/src/mcp_runtime.cj`, `agent_product/src/vnext_control.cj` | Bounded static inspection covers Pi, Codex, and Axyndra manifests. Local imports use controlled materialized paths. Typed Git requests pin an exact commit. Typed npm requests pin an exact semantic version. Both require explicit approval and use the prepared Bash control. npm lifecycle scripts are disabled. The dependency lock records SHA-512 integrity for the root and transitive packages. Imported snapshots are content-locked and disabled by default. An exact Git cache hit reuses the verified snapshot without creating a Run. The existing Pi JavaScript and TypeScript host, Skills, MCP, and Axyndra activation paths remain. These do not establish upstream Pi or Codex compatibility. | `plugin_package_test`, `product_thread_runtime_contract` |
| Extension-author SDK | `agent_sdk/src/extension.cj` | Versioned authoring contract for cooperative extensions; defines no Agent execution, approval, or persistence authority | `compatibility.md`, `extension_runtime_contract` |
| Internal embedding facade | `agent_embed/src/sdk.cj` | `AgentBuilder` 显式注入 Provider/Store/Policy/Budget 并组装既有 AgentCore；与 extension-author `agent_sdk` 是不同入口 | `sdk_contract` |
| Headless/JSONL | `agent_embed/src/headless.cj`, `agent_app` | typed exit status、UTF-8 JSONL、可插入 redactor、审批 continuation/cancel | `sdk_contract`, `artifact_contract` |
| Public SDK testkit | `axyndra_agent_testkit` | deterministic clock/ID/cancellation、pure extension contract harness、experimental named fault plan；JSON 值由 yjson 提供 | `testkit_consumer`, `testkit_extension_contract` |
| Internal Agent testkit | `agent_testkit` | scripted Model/Tool/policy、Run/Operation port doubles、audit recorder、benchmark 分位数；仅内部测试依赖 | `testkit_contract`, `chaos_contract`, `extensions_contract` |
| Coding Agent tools | `agent_product` | read/search/edit/shell 受 workspace、approval、operation receipt 与 audit 约束 | `product_contract`, `worktree_contract` |
| Planning/Subagent/Task | `agent_core`, `agent_runtime`, `task_runtime`, `run_control` | 子任务仍使用 AgentCore；权限、取消和预算不因委派消失；`subagent_runtime` 目前只是 workspace 外的说明占位 | `orchestration_contract`, `task_persistence_contract` |
| TUI / RPC / CLI | `agent_tui`, `agent_rpc`, `agent_cli`, `agent_app` | CLI/TUI 无 Core/Store 依赖；app/RPC 保留既有 Core 边，分别供入口层 Model Attempt/history 映射与 reviewer dry-run、RPC run-mode 映射；无前端 Store 依赖 | `agent_cli_contract`, `client_contract`, `product_rpc_contract` |
| Run inspection projection | `agent_product/src/run_inspection.cj`, `run_inspection_render.cj` | `/inspect [run-id] [before-operation-cursor]` reads canonical evidence without invoking the model; CLI/RPC/TUI share the typed query and frontends own no recovery state | `product_thread_runtime_contract`, `product_rpc_contract`, `tui_path_coverage` |
| Read-only programmatic tool calling | `agent_product/src/program_runtime.cj`, `program_worker.cj`, `agent_store/src/operation_runtime_store.cj` | A committed `run_program` root starts one isolated worker; every child is a persisted derived Operation using the parent budget, frozen capability ceiling, and read-only broker. Nested/writable PTC and Python PTC are unsupported | `product_thread_runtime_contract`, `direct_runtime_sandbox_contract`, `fault_matrix` |
| Controlled file-plan application | `agent_product/src/file_application_plan.cj` | Read-only proposal, immutable plan, canonical `apply_file_plan`, approval, and per-file result are separate stages; stale/partial/unknown effects never trigger blind retry | `product_thread_runtime_contract`, `product_contract`, `tui_path_coverage` |
| Isolated JavaScript extension host | `agent_extension_runtime`, `agent_product/src/plugin_runtime.cj` | Versioned bounded IPC, per-plugin/Thread state, frozen generations, controlled service broker, cancellation, rollback, and explicit missing-runtime/isolation failure. Only the documented Pi/Codex subset is supported | `extension_runtime_contract`, `extensions_contract`, `product_thread_runtime_contract`, `compatibility.md` |
| Relocatable product candidate | `scripts/package_candidate.sh` | Linux x86_64 executable and non-system libraries use `$ORIGIN`; default startup works without checkout, SDK, `LD_LIBRARY_PATH`, Node, or Bun. Optional extension facilities diagnose missing dependencies and never fall back to bare execution | `package_candidate_clean_env`, `package_readiness_gate` |

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
| #36 / later E1–E4, P/R | `agent_product/src/program_runtime.cj`; `agent_product/src/vnext_control.cj`; `support_tests/product_thread_runtime_contract/src/main.cj`; `agent_store/src/operation_runtime_store.cj` | E3-03/04 verified. E3-05: approval children settle Rejected; Draining blocks admission; rerun uses a fresh Run ID. E3-06: canonical root/child Receipts, verified source hash, oversized result is Partial/Null. E3-07: cancellation retains child #1 Receipt, withholds completed root output, settles Run as cancelled, and cleans the worker directory. E3-08: three deterministic matched fixture pairs run native grep/read/read and read-only PTC under the same prompt; path/content evidence matches exactly; root/child plans are WorkspaceRead-only with Denied networking. Native missing-read and PTC denied-write failures remain observable. Active-read cancellation settles the native Run without a follow-up provider request; PTC cancellation contract remains verified.| P-04 fixed-task benchmarking remains open; fixture costs are unpriced and elapsed times are descriptive, not provider performance evidence. Remaining E1–E5 and P/R work stay open.| `product_thread_runtime_contract`; `tool_runtime_contract`; `agent_store_contract` | Product Thread Runtime: PASS via `scripts/pinned_cangjie cjpm run` (build + run wall 229.25s); three matched pairs. PTC: 572–584ms, 2 model requests, 4 input/2 output tokens, 1 tool call, 4 Operations/Receipts. Native: 760–811ms, 4 requests, 10 input/4 output tokens, 3 tool calls, 3 Operations/Receipts. Full usage fields emitted; fixture cost unpriced and timings fixture-only. Tool Runtime build + executable PASS (42.12s); Agent Store build + executable PASS (46.53s). E3 admission: ProductVnextControl.executePluginAcquisitionControl accepts only synchronous non-PTY Bash with an explicit parseable network policy and delegates to canonical prepared execution. Explicit Denied is valid: the contract runs a fixed local command without NetworkAccess and verifies the Denied normalized plan; missing policy, async, and PTY are rejected before Run. HostNetwork normalization, canonical ToolCall/ToolResult, Operation, and Receipt are also verified; actual Git/npm locks/install remain E2-07.| Tool Runtime verifies revocation rejects stale output; Agent Store verifies plan-identity conflicts. Unexpected worker exception/IPC-disconnect paths are source-inspected, not separately fault-injected. | Deliver issue 34 M1 declarative plugins; complete issue 36 E2-07 locked Git/npm sources.|
- The E0-01 rows above are a historical baseline. Current #34/#35/#36 product evidence is indexed in [Compatibility and release policy](compatibility.md#integrated-implementation-and-release-evidence). Dedicated executable contracts now cover the isolated JavaScript host, Pi/Codex subset, per-Thread state, eval separation, controlled services, packaged no-plugin startup, exact-commit local Git, exact-version loopback npm, update/rollback, read-only PTC, and controlled plan application. Public Git/npm endpoints, the protected real-provider smoke, non-Linux platforms, other Node/Bun/Cangjie profiles, and long soak matrices remain unverified.

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
- PR #38 CI: [PR gate run](https://github.com/lIlIIlIll/Axyndra/actions/runs/35452447524) concluded **success** at head `cf2b614948228db86278a66c4f8d54b7f045c002`; the single `clean-build-test` job completed all configured steps, including focused contracts, product regression fixtures, CI evidence writing and artifact upload.
- The local baseline remains the evidence record for exact one-sample wall times. The PR run is an independent clean-build confirmation, not a replacement for the explicitly unrun provider, PTY/TUI, package-readiness, release, and later roadmap matrices.

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

## E0-01 基线审计：状态所有权与回归入口

审计锚点为 `HEAD` `9eb7658cd63788421ec6d4d756a635d47c5b3262`，审计日期为 2026-09-24。审计时工作树有未提交修改，包括 `agent_core`、`agent_domain`、`agent_product` 和插件宿主相关文件。本节映射当前检视的源码，不把未提交修改归于锚点提交；表格列出的回归入口仅作索引，执行情况见 E0-02。

| 状态或职责 | 所有者与调用路径 | 拆分风险与回归入口 |
| --- | --- | --- |
| Thread 语义事实 | `ThreadCoordinator` 是单个 Thread 的语义提交者；`AgentThreadRuntime` 是唯一公开的活跃 Thread 可变所有者；`ThreadCommitSink` 将转换交给持久化实现。`AgentCore.start()` / `resume()` 通过 `ThreadRuntimeRegistry` 获取该运行时。 | 不把 canonical Thread 状态复制到 `AgentCore`、工具或插件中。回归入口：`thread_runtime_contract`、`thread_runtime_integration_contract`、`product_thread_runtime_contract`、`agent_store_contract`。 |
| Model Attempt 与 Decision | `AgentCore` 保持唯一模型循环并编排 Attempt；`model_control.cj` 提供 deadline/recovery 策略和受控模型端口；`DurableModelAttempt` 与 `ModelDecisionRuntimePort` 记录 Attempt/Decision 事实，canonical Thread 提交仍走运行时端口。 | `core.cj` 同时包含请求、重试、Attempt 结算、恢复和工具调用衔接。工作树差异新增 provider transcript snapshot 的保存/校验；必须继续证明旧快照不能绑定到不同请求。回归入口：`agent_core_contract` 的 `durable_trace_contract.cj`、`agent_domain_contract`、`model_adapters_contract`。 |
| Run、预算与取消 | `AgentThreadRuntime` / `RunLifecycle` 管理活跃 Run 和异步任务；`CoreRunControl` 持有进程内取消源、执行预算计数和当前批次等控制数据。`ResourceBudget` 是请求限额输入。 | 区分持久化 Run 转换与控制器缓存；不得建立第二份总预算，取消不得越过 Attempt/Operation 结算。回归入口：`agent_core_contract`、`product_continuation_contract`、`support_tests/product_contract/src/process_output_cancel_contract.cj`。 |
| Tool batch、审批与 Receipt | `AgentCore` 把已提交的工具调用交给 `CoreToolBatchCoordinator`；它按资源冲突划分 wave，并在首个待审批调用处停止后续准备。`ToolPipeline` 执行准备、策略、审批、执行与结果提交；`OperationRuntimePort` 管 canonical Operation 事实。 | 不能从模型草稿执行、越过审批屏障、重放已有 Receipt 或盲目重试未知副作用。回归入口：`support_tests/agent_core_contract/src/durable_trace_contract.cj`、`tool_runtime_contract`、`approval_reviewer_contract`、`product_continuation_contract`。 |
| 产品装配与插件边界 | `agent_product/src/product.cj` 建立 `ToolPipeline` 与 `AgentCore`，并把同一个 Operation runtime 传给两者；`tools.cj` 组装目录。插件 JS 宿主是可选工具提供方，仍通过现有 pipeline 和产品沙箱。 | 新宿主不能另建 Agent loop、Operation store 或执行旁路。回归入口：`product_contract`、`extension_runtime_contract`、`agent_product` 的 `PluginRuntimeContractTests`。 |

本表是 E0-01 锚点的职责快照，不表示当前 roadmap 状态。E0-03 至 E0-05 的实现与验证见下文；E0-06 的 Product 组合与前端依赖边界证据见下文对应小节。工作树中的 `session_approval_allowed` 字段仍服从宿主审批状态，不构成独立授权。

本审计验证源码所有权、调用路径、回归入口和工作树差异；E0-02 的实际执行结果见下节。

## E0-02 关键轨迹的运行证据

- 环境：Linux x86_64；Cangjie STS SDK 1.1.3。通过仓库 `scripts/pinned_cangjie` 运行；构建、SDK 校验缓存、运行时目录和 `TMPDIR` 均指向本次任务的磁盘临时目录。
- 命令：`cd support_tests/agent_core_contract && ../../scripts/pinned_cangjie cjpm run`。
- 结果：退出码 0，程序输出 `agent_core contract passed`；编译器报告 27 条警告。
- 轨迹断言：同一套件覆盖模型失败/精确重试、审批暂停与恢复、取消和 Run deadline 的重放屏障、Draining 收尾、迟到模型结果不能覆盖 `RecoveryRequired`，以及模型崩溃恢复时冻结请求和事件顺序。
- 持久化故障断言：`support_tests/agent_core_contract/src/durable_trace_contract.cj` 强制模型 dispatch、Receipt 持久化和未知副作用三个崩溃窗口；Receipt 重放返回相同输出且副作用计数保持 1，未知副作用要求 reconciliation，拒绝盲目重试且不伪造 Receipt/ToolResult。

本次只运行 `agent_core_contract`。其他 E0 合同包、产品/TUI PTY、真实 Provider 和发布门禁尚未由此命令验证；后续阶段需按各自验收继续运行。

## E0-03 模型请求与 Attempt 职责收敛

- `agent_core/src/model_control.cj` 负责 attempt 请求计划（有效请求、policy、重试 identity）及失败/replay-barrier 分类；`AgentCore.executeModelWithTurnRetry` 仍是唯一重试循环。恢复路径继续消费已持久化的冻结请求，不重新解析 checkpoint 中的 wire controls。
- `AgentCore.dispatchClaimedModelAttempt` 收敛已 claim attempt 的启动事件、单次 provider 执行、usage 记录和 deferred replay-barrier 持久化。retry 路径的记录失败 settlement 与 no-retry/resume 的既有差异由显式参数保留。
- terminal validation、Decision lifecycle 和 provisional-event settlement 仍分别由 `durableResultForAttempt`、`recordDurableDecisionLifecycle` 与 `settleProvisionalModelEvents` 处理；没有增加第二个状态 owner、重试 loop 或持久化层。
- 验证：对以上改动重新运行 E0-02 命令，退出码 0，输出 `agent_core contract passed`；现有契约覆盖 retry identity、failed-attempt usage、取消/Run deadline replay barrier 与 durable restart 的冻结请求。编译仍报告 27 条警告。该运行不证明真实 Provider、TUI PTY 或 release gate。



## E0-04 预算与 Run 控制证据

- `CoreRunControl.ledger` 是父 Run 累计预算的唯一准入与结算来源，覆盖常规模型请求、子 Run 和绑定到 Core 的内部模型调用。`RunSnapshot` 持久化请求数与实际用量，供恢复和检视使用，不再作为第二份累计预算准入器。
- `ChildBudgetPool` 只管子 Run 数量、并发和生命周期。父 ledger 负责预留子预算并结算实际用量；子任务预算不能超过父 Run 剩余限额。零值子预算表示未设置子级上限，不会取消父级上限。
- 生产 `ApprovalReviewer` 使用与 `AgentCore` 绑定的同一个 `ControlledModelPort`。它的请求预留、失败或超时用量及 cost 都进入父 ledger；只有显式 standalone 维护调用使用调用级账本。
- Provider 已报告的失败和 timeout 用量，即使超过请求或 Run 限额，仍先记录实际 token/cost，再返回预算错误。受控内部请求还检查父 Run deadline 与取消状态。RunSnapshot 保留持久化证据，Core ledger 执行累计 admission。
- 验证环境：Linux x86_64，STS Cangjie SDK 1.1.3。`support_tests/agent_core_contract` 退出码 0，输出 `agent_core contract passed`；覆盖父级累计限额、内部模型请求计数、失败/timeout 用量和 deadline/cancellation。`support_tests/child_run_vnext_contract` 输出 `vNext child run contract passed`；覆盖子预算预留、settlement、超额用量保留、零值 sentinel 和父 deadline。`support_tests/subagent_product_contract` 输出 `subagent product contract passed`；`support_tests/approval_reviewer_contract` 输出 `approval_reviewer contract passed`。
- 先前的一次 `support_tests/product_contract` 运行在 caller `PATH` 断言处失败。E1-02 记录了修正显式 allowlist `PATH` 与 sandbox Xauthority 后的 `process-remediation` 聚焦验证。完整 package 仍未验证。
- 尚未运行压力/并发 soak、真实 Provider 成本对账、跨平台配额矩阵和完整 #36 门禁。本节只证明列出的 Linux focused contracts，不表示 E0 阶段或 #36 完成。

## E0-05 工具批次、审批恢复与 Run 收尾证据

- `CoreToolBatchCoordinator` 在首个 `NeedsApproval` 处停止准备；后续已提交调用保留为 deferred refs，不生成 Prepared Operation。`AgentCore.decide` 校验并记录 durable approval decision，再通过现有 `ToolPipeline` 执行批准项，并把 deferred refs 交回同一批次路径。
- `AgentThreadRuntime.finish` 通过 `RunLifecycle` 的 `RunScope` join 已拥有的任务，再按 settlement report 选择终态。未完成任务进入 `RecoveryRequired`；失败的子任务不能被记作成功完成。join 开始后 Run 不再接纳新任务。
- `agent_core_contract` 的 `approvalBatchBarrierContract` 验证 A 先执行、B 等待审批、C 不越过屏障；审批后 B 和 C 各执行一次，且事件顺序保持稳定。其 `support_tests/agent_core_contract/src/durable_trace_contract.cj` 验证重复读取已提交 Receipt 返回相同结果，外部副作用、Operation、approval、handoff、Receipt 与 ToolResult 各保留一份。
- 验证环境：Linux x86_64，STS Cangjie SDK 1.1.3。`support_tests/agent_core_contract` 输出 `agent_core contract passed`；`support_tests/run_lifecycle_vnext_contract` 输出 `vNext run lifecycle contract passed`；`support_tests/product_continuation_contract` 输出 `product continuation contract passed`。后者覆盖结构化 continuation 持久化和旧格式迁移，不单独证明进程重启后的真实 Provider 恢复。
- 本次审计没有引入第二个批次协调器、审批状态仓库或 Run 生命周期 owner。该证据不覆盖完整 UI/PTY 审批、跨平台并发压力或全 #36 故障矩阵。

## E0-06 Product 组合与依赖边界证据

- `agent_product/src/product.cj` (`openProduct`) 保持产品 composition root；工具按 `agent_product/src/tools.cj` 的必需/可选能力组装；进程与沙箱构造由 `agent_product/src/local_infrastructure.cj` (`createProductProcessPort`) 承担。该 helper 为 package-internal，未新增 public API。
- `agent_sdk` 是版本化 extension-author API；内部 `AgentBuilder` 属于 `agent_embed`。两者保持不同入口。
- 四个前端均无 `agent_store` 直接依赖/import；`agent_cli`、`agent_tui` 保持 Core-free。`agent_app` 的既有 Core 边供入口层 Model Attempt/history 映射和 reviewer dry-run；`agent_rpc` 的既有 Core 边映射 run-mode 枚举。本轮没有新增这些边。
- 验证：`bash scripts/architecture_gate.sh` 通过；`agent_app` 的 `cjpm build` 成功；`support_tests/product_contract` 的 `session-lifecycle` scope、`support_tests/product_rpc_contract`、`support_tests/agent_cli_contract` 均退出码 0，分别输出 `product session lifecycle contract passed`、`product_rpc contract passed`、`agent_cli contract passed`。session fixture 未导入外部插件。
- 此前完整 `support_tests/product_contract` 运行在 caller `PATH` 断言处停止。E1-02 后续聚焦验证覆盖了 PATH、Xauthority 与进程生命周期。本节不声明完整 package 通过。

## E1-01 类型化执行配置与能力边界

`ProcessRequest` 是不可变的进程执行描述，包含 executable、working directory、timeout、sandbox mode、冻结的 `NetworkPolicy`、环境 allowlist 与 redaction 输入。`ProcessPort` 只提供 `execute(request)` 和 `cancel(operationId)`，执行器不需要通过服务定位器取得 Core、Store 或凭据。

`agent_product/src/eval_runtime.cj` (`EvalRuntimeProfile`) 定义每种 Eval 语言的兼容 profile、默认命令、runner 参数和 persistent-session/reset 能力。profile ID 的 `v1` 标记宿主 eval 协议约定，不是解释器二进制版本。`agent_product/src/tools.cj` (`EvalTool.execute`) 在 eval 调用时选择运行时；产品初始化不探测或强制安装可选解释器。

可用 `AXYNDRA_EVAL_PYTHON_EXECUTABLE`、`AXYNDRA_EVAL_JS_EXECUTABLE`、`AXYNDRA_EVAL_RUBY_EXECUTABLE` 或 `AXYNDRA_EVAL_JULIA_EXECUTABLE` 指定解释器路径。覆盖值必须是已存在的绝对路径；相对路径返回 `eval.interpreter_path_invalid`，不存在的路径返回 `eval.interpreter_unavailable`，诊断不回显配置值。未设置时使用 `python3`、`bun`、`ruby` 或 `julia` 命令名，由沙箱受控搜索路径解析。自定义路径仍须位于已挂载的沙箱根内；越界时返回 `sandbox.executable_outside_roots`。

`EvalTool.execute` 将选中的 executable 与 `prepared.operationPlan.networkPolicy` 一起传入 `ProcessRequest`。`LocalProcessPort` 只接受网络策略为 Denied 的 Eval 请求；`WorkspaceSandbox.plan` 解析最终 executable，并把 `resolvedExecutable`、受限环境和沙箱 argv 放进 `SandboxLaunchPlan`。解释器配置变量只用于选择 executable，不进入子进程环境。

代码实现范围与契约测试基线分开记录：

| Eval language | 当前 profile / 默认命令 | `product_contract` 基线 |
| --- | --- | --- |
| `py` | Python / `python3` | 持久状态、reset、cell timeout 与取消有契约覆盖。 |
| `js` | Bun / `bun`；不是 Node profile。 | 持久状态与运行时错误有契约覆盖。 |
| `rb` | Ruby / `ruby` | 持久状态与运行时错误有契约覆盖。 |
| `jl` | Julia / `julia` | 源码 profile 存在；当前 `product_contract` 未执行此运行时。 |

这些 profile 表示源码提供了对应 runner，不保证主机已安装解释器。当前没有声明外部解释器的支持版本区间，也没有采集二进制版本；不能把 profile ID 当成该版本证据。

`support_tests/product_contract/src/main.cj` (`runEvalContracts`) 是上述 Eval 运行行为的黑盒回归入口。E1-01 的路径错误诊断另由 `eval-runtime-config` scope 验证。

- 验证环境：Linux x86_64，Cangjie STS SDK 1.1.3；构建缓存、SDK 校验缓存、运行时目录和 `TMPDIR` 位于本次任务的磁盘临时目录。
- 命令：`cd support_tests/product_contract && AXYNDRA_PRODUCT_CONTRACT_SCOPE=eval-runtime-config ../../scripts/pinned_cangjie cjpm run`。退出码为 0，输出 `product eval runtime configuration contract passed`。该 scope 验证相对/缺失路径诊断与路径脱敏，并执行现有 Python、Bun、Ruby eval 行为合同。
- 未验证项：有效的自定义绝对路径覆盖、Julia runner、外部解释器版本区间、其他平台和完整 `product_contract` 套件。`process-remediation` 的 PATH 与 Xauthority 检查见 E1-02，不代表完整套件通过。

- `cd support_tests/sandbox_contract && ../../scripts/pinned_cangjie cjpm run` 退出码为 0，输出 `sandbox_contract: all contracts passed`；覆盖 ProcessPort 的文件/网络隔离与 persistent Eval sandbox 行为。

## E1-02 共享进程生命周期

`LocalProcessPort` 用 `operationId` 在 `reserved` 和 `active` 中跟踪调用。执行入口先检查预留的取消；若取消与启动竞态，`register` 登记子进程后立即终止它。Shell 和 Eval 进程也经过同一活动注册表。

`ActiveLocalProcess` 保存 PID 启动时间，避免 PID 重用后误杀其他进程。`SubProcess` 由 `process4cj.terminateProcessTree` 做身份校验和进程树处理：先发送 `SIGTERM`，宽限后重新捕获子进程，再强制结束仍存活的进程；sandbox 启动则由 `ManagedProcess` 持有，并复用其 TERM/KILL 进程树生命周期。`WorkspaceSandbox.execute` 在启动回调中登记 managed handle，并发读取 stdout 和 stderr；共享字节预算限制输出收集量。

启动失败和传输失败返回具体 `AgentError`。`ProcessResult` 保留退出码、超时和截断状态。ToolPipeline 将调用取消呈现为取消错误。Eval 首次请求后的写失败、空响应、格式错误和宿主等待超时分别得到传输错误、`transportClosed`、协议错误或 `timedOut`。`LocalProcessPort.executeEval` 丢弃已关闭或错误的内核；JavaScript 超时也会丢弃内核。

`EnvironmentFilter` 只在显式 allowlist 包含 `PATH` 时保留调用方路径；其他 sandbox 请求仍使用受控 PATH。Display-server 请求选择显式 `XAUTHORITY`，或从主机 `HOME` 派生 `.Xauthority`；存在的 authority 文件以只读方式挂载。
`support_tests/product_contract/src/process_output_cancel_contract.cj` 覆盖异常退出码、无效 UTF-8、输出上限、stdout/stderr 并发读取、重复进程启动后的文件描述符计数、启动中取消、`SIGTERM` 协作退出与忽略 `SIGTERM` 后强制终止、逃离 session 的后代进程与工作线程子进程回收、不同 Run 的并发取消，以及无响应 Eval 的清理和同一 Session 的恢复。

- 验证环境：Linux x86_64，Cangjie STS SDK 1.1.3。
- `cd support_tests/product_contract && AXYNDRA_PRODUCT_CONTRACT_SCOPE=process-remediation ../../scripts/pinned_cangjie cjpm run` 退出码为 0，输出 `process lifecycle, eval startup, output and cancellation contracts passed`。该 scope 验证上述生命周期合同及显式 PATH、Xauthority 环境。
- `cd support_tests/sandbox_contract && ../../scripts/pinned_cangjie cjpm run` 退出码为 0，输出 `sandbox_contract: all contracts passed`。默认 PATH 仍由 sandbox 控制；只有 allowlist 明确授权时才保留调用方 PATH。
- 其他平台和完整 `product_contract` 套件未验证。E1-04 负责版本化 IPC；E1-07 负责把现有 Eval 执行逻辑迁移到共享设施。本节不声明这两项已完成。

## E1-03 受控执行环境与隔离适配

`WorkspaceSandbox.availability` 和 `execute` 都通过 `process4cj.startProcess` 启动隔离 launcher。两者都将 `ProcessCommand.terminateProcessTree` 设为 `true`。native process supervisor 会在 exec 前关闭无关的继承文件描述符。两条路径都在 `finally` 中关闭 `ManagedProcess`。`execute` 把句柄登记到 `LocalProcessPort` 的 `active` 集合。启动竞态取消会使用该句柄。取消先发 `SIGTERM`，再升级到 `SIGKILL`。

子进程环境由 `--clearenv`、`EnvironmentFilter` 过滤的显式条目、运行时设置的 `HOME`、`TMPDIR` 和 `LANG`，以及默认受控或显式授权的 `PATH` 构成。只有 allowlist 包含 `PATH` 时才保留调用方的值。`/tmp` 在每次 bubblewrap 启动中挂载为私有 tmpfs。除 `Host` 模式外，系统和工具链根以只读方式挂载，工作区按策略以只读或读写方式挂载。拒绝和中介网络模式均阻断直接网络访问。

`support_tests/sandbox_contract` 在 Linux 上用真实 bubblewrap 验证未挂载的邻接文件不可读、每次启动的 `/tmp` 相互隔离、只读工具链挂载拒绝写入。文件描述符探针在 `RLIMIT_NOFILE=64` 时未发现高于 3 的描述符。该套件也验证受控环境、工作区只读与读写挂载、直接 loopback 拒绝和中介 gateway 成功。

## E1-04 有界且绑定身份的 Extension Host IPC

`agent_extension_runtime/src/javascript_host.cj` 使用 `axyndra-js-host-v2`。宿主在 `hello` 帧中发送扩展 ID、版本、host generation 和宿主批准的能力列表。`ready` 必须逐项匹配这些字段，并且只能确认同一份无重复能力列表。扩展的响应不能授予自身能力。

宿主生成 invocation ID，并将 Thread、Run、epoch、Operation、call 和工具名绑定到每条调用帧。进度帧和终态帧都必须回显完整身份。任一字段不匹配时，宿主关闭该进程并返回 `extension.protocol_identity_mismatch`。每个 host 只接受一个未决调用；并发调用返回 `extension.invocation_busy`。

IPC 限制如下：

- 帧以换行分隔。默认最大帧为 262144 字节，可配置范围为 1024 至 4194304 字节。
- 握手和调用 JSON 的最大深度为 32。工具注册帧也受帧大小限制。
- 扩展 ID、版本以及每个 Thread、Run、Operation 和 call ID 最多 256 字节。能力列表最多 128 项，每项最多 256 字节。
- 一个 invocation 最多接收 128 个进度帧。超过上限或帧解析失败会关闭 host。
- 宿主单独排空 stderr。stderr 不进入 stdout 协议解析，也不会积累为宿主侧日志或结果。
- 取消帧绑定当前 invocation 身份。宿主等待取消确认最多 100 ms，然后强制回收进程树。空闲关闭也等待最多 100 ms，再强制结束仍存活的进程。

验证环境为 Linux x86_64 和 Cangjie STS SDK 1.1.3。

- `cd support_tests/extension_runtime_contract && ../../scripts/pinned_cangjie cjpm run` 退出码为 0，输出 `extension manifest/runtime contract passed`。真实 Node 与 TypeScript fixture 覆盖协议版本、扩展 ID/版本、generation、能力确认、完整 invocation 身份、伪造进度 ID、重复终态、断连、帧和 JSON 深度上限、进度上限、stderr 排空、单 host 并发限制、协作取消、无确认时的强制终止及超时。
- `cd agent_product && ../scripts/pinned_cangjie cjpm test` 退出码为 0，33/33 tests 通过。该包回归也覆盖产品插件宿主和隔离启动路径。

其他操作系统和非 Node 宿主尚未验证。上述协议 fixture 使用直接 process launcher 隔离验证 IPC 行为；产品测试验证 Linux 产品 launcher。该证据只完成 E1-04，不证明 #34/#35 的真实上游扩展兼容、hooks、交互或远程依赖获取。
