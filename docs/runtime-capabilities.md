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
| Workspace Sandbox | `sandbox_runtime` | bubblewrap namespace、mount、resource limit、最小环境；宿主不支持时 fail-closed | `sandbox_contract` |
| Secret 与环境边界 | `sandbox_runtime`, `agent_product` | 环境默认拒绝、显式 allowlist、启发式 secret 名和已知值脱敏 | `sandbox_contract`, `product_contract` |
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
| Planning/Subagent/Task | `subagent_runtime`, `task_runtime`, `run_control` | 子任务仍使用 AgentCore；权限、取消和预算不因委派消失 | `orchestration_contract`, `task_persistence_contract` |
| TUI / RPC / CLI | `agent_tui`, `agent_rpc`, `agent_cli`, `agent_app` | UI 不依赖 Core/持久化；命令不伪装成 Prompt；所有入口消费同一 Runtime | `agent_cli_contract`, `client_contract`, `product_rpc_contract` |

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
