> Review draft (2026-10-12): see [current changes, actual failures and pending acceptance](issue-45-draft-status.md). No Epic completion is claimed.

# Plugin-first migration baseline (#45)

> SDK retirement candidate: current Native author-source packages are v3, while the original Native wire SDK stays 2.1. The empty compiled Product runtime, old SDK business bridge and fake extension UI are removed in this source candidate; full historical oracles run only in Support. See [compatibility](compatibility.md). Older rows/timings below record the original baseline, not current SDK or acceptance claims. Actual joined compilation and all Root/capacity acceptance remain pending.

> Skills migration: current production uses the installed Skills ContextProvider and canonical generic context reads; see [installed Skills context](skill-routing.md). Older test timings and legacy type names below are historical evidence, not validation of this replacement.

本页记录 [#45](https://github.com/lIlIIlIll/Axyndra/issues/45) 的实施基线和验收入口。
设计见 [ADR 0004](adr/0004-plugin-first-host-boundary.md)。本页不是 Epic 完成声明。
当前原生进程协议、支持子集与示例见 [进程插件协议](plugin-process-protocol.md)。

Issue 范围没有获准缩减，阶段性产物不等于 Epic 完成。

## 当前源码候选与验证边界（2026-10-11）

当前组合的独立插件源码位于 `plugins/*`，Minimal 使用 `agent_minimal`。
发行配方 `packaging/distributions.json` 分别选择空插件 Minimal、9 个插件的 Coding
和 17 个插件的 Full；随附、默认启用、Core 必需独立记录，安装不产生授权。
具体列表及构建入口见 [发行配方](distribution-profiles.md)。

MCP Client/Server、AST、网页搜索、GitHub、LSP、DAP、eval、Workspace、Shell、
Shell Readonly、Program、Skills、Memory、Compaction、Workflow 和模型适配器各有
独立包。生产模型选择使用已安装贡献，缺失或禁用不回退静态 adapter。
这些是当前源码归属及装配事实，不能代替真实安装、执行、禁用、恢复和发行验收。

当前源码中 Task/Yield 的解析、策略和结果组装由已安装的 Workflow Native 包负责。
Product 的默认 Hub 业务入口已移除；显式安装的 peers/messages/jobs/cancel/process
工具族复用 Native 原有算法。Host 保留真实 Run、状态、权限、取消、进程和 Receipt 原语。
原 Product、Support 与 TUI 合同已接显式工具选择；此迁移仍待真实编译和完整合同执行。
错误输出的所有权、真实 Future/进程返回、部分写入与取消后的清理也继续验证。
当前整树尚无完整编译和运行通过结论，30 个 A0–A7 项目及完成定义仍需逐项验收。
旧日志、测试数量、性能样本和通过结果均保留其原始源码与环境范围，不能拼接为
本候选通过。下面的依赖地图、计数和状态表记录起始版本或标明的历史检查点。

## 起始盘点与历史验证

以下内容保留原始记录。出现“当前”“仍存”或 `Done` 时，只指对应日期与源码
检查点；当前候选的依赖和产物必须重新检查，历史失败不会被后续修复覆盖。
退休源码的历史链接固定到经核对的 #43 提交，不是当前安装或执行入口。
当前实现分别见 [Program](../plugins/program/src/main.cj)、
[Eval](../plugins/eval/src/main.cj)、[LSP](../plugins/lsp/src/configuration.cj)、
[MCP 迁移](mcp-plugin-migration.md)；其余插件按上文发行配方选择。

## 核对范围

- 核对日期：2026-10-04。
- 起始 HEAD：`4d88fa6072f7176a6d236a1cb39b33529d5b609d`，提交标题为
  `Complete canonical runtime, plugin integration, and reliability evidence (#43)`。
- 该版本恰好是 issue 创建时的基线；没有把 #43 之前的限制冒充当前实现。
- 本页的初始行为表来自源码和已有测试入口。既往文档的 Linux 运行记录不代表
  在本次工作树重新通过了构建、性能、隔离或产品测试。

## 依赖与执行迁移地图

| 范围 | 当前所有者 / 入口 | 可复用部分 | 必须迁移或补齐 |
| --- | --- | --- | --- |
| 包管理 | `agent_product/src/plugin_runtime.cj`、`agent_product/src/plugin_acquisition.cj`、`agent_product/src/plugin_maintenance.cj`、`agent_extension_runtime/src/plugin_package.cj` | 静态检查、来源锁、摘要、快照、启停状态、staging、更新/回滚/GC；维护获取已不调用 BashTool；删除旧 Web 路径后的无模型 CLI 全生命周期和全新包门禁已实测通过 | 通用组件依赖、完整贡献目录与发行矩阵 |
| 进程宿主 | `agent_extension_runtime/src/javascript_host.cj`、`agent_product/src/javascript_plugin_host.cj`、`agent_product/src/javascript_plugin_service.cj` | 原生可执行端点复用有界 IPC、generation、取消、隔离 launcher、受控 broker；已有 Tool/Command 贡献；Direct 根准入、只读包进程及文件计划服务已有真实定向证据 | 其他贡献种类；完整服务级授权、挂起和未知效果恢复 |
| 旧原生 SDK / 业务分发 | `agent_sdk/src/extension.cj`、[agent_extensions/src/extensions.cj (historical #43)](https://github.com/lIlIIlIll/Axyndra/blob/4d88fa6072f7176a6d236a1cb39b33529d5b609d/agent_extensions/src/extensions.cj)、`agent_product/src/tools.cj` | 参数/计划校验、ToolPipeline 和 canonical 执行链；AST 与网页搜索业务分支已删除 | `HostOperationIntent`、`ProductExtensionOperationHost` 仍让宿主执行 workspace 文件搜索/写入；注册包装不能视为外迁 |
| MCP Client | [agent_product/src/mcp_runtime.cj (historical #43)](https://github.com/lIlIIlIll/Axyndra/blob/4d88fa6072f7176a6d236a1cb39b33529d5b609d/agent_product/src/mcp_runtime.cj)、`extensions/mcp_extension/src/mcp_extension.cj`、`agent_mcp`、`libs/mcp4cj` | 已有协议、transport、发现/调用/取消契约；MCP adapter 已从通用 `agent_extensions` 拆出 | 产品仍链接独立 adapter package；客户端配置、发现、连接、tool bridge、协议依赖仍须归属可安装 MCP 插件 |
| MCP Server | [agent_product/src/product_mcp_server.cj (historical #43)](https://github.com/lIlIIlIll/Axyndra/blob/4d88fa6072f7176a6d236a1cb39b33529d5b609d/agent_product/src/product_mcp_server.cj)、[agent_app/src/mcp_server_cli.cj (historical #43)](https://github.com/lIlIIlIll/Axyndra/blob/4d88fa6072f7176a6d236a1cb39b33529d5b609d/agent_app/src/mcp_server_cli.cj) | 外部请求进入既有受控执行的基础 | Server 组件、启动命令独立交付；外部 principal 不伪造模型决定；防止导出循环 |
| AST / web search | `plugins/ast`、`plugins/web_search` | AST 查询/编辑和 Brave/Tavily/Searx 业务均已外迁，旧宿主实现、静态 package 和专属 search CLI 已删除；复用通用只读进程、不可变文件计划和受控 HTTP；删除后的相关合同、122 项 Product 单元、真实 CLI 管理/调用及全新包门禁已通过 | 完整发行及性能矩阵按 A0/A7 继续验收 |
| GitHub | [agent_product/src/github_tool.cj (historical #43)](https://github.com/lIlIIlIll/Axyndra/blob/4d88fa6072f7176a6d236a1cb39b33529d5b609d/agent_product/src/github_tool.cj) | 网络/进程/凭据和效果管线 | API/CLI、schema、命令、结果由插件持有 |
| LSP / DAP | `plugins/lsp`、`plugins/dap`、`libs/lsp4cj`、`libs/dap4cj` | 进程控制、文件审批、工作区版本 | 两个独立安装和生命周期；Product 内建 DAP 已删除，原完整调试合同迁移到公开 canonical 入口，当前二进制验收待运行 |
| eval | [agent_product/src/eval_runtime.cj (historical #43)](https://github.com/lIlIIlIll/Axyndra/blob/4d88fa6072f7176a6d236a1cb39b33529d5b609d/agent_product/src/eval_runtime.cj)、`agent_product/src/tools.cj` | 隔离、进程回收、取消、预算 | 语言运行器和连续单元私有状态外迁；不共享插件宿主/PTC 解释器状态 |
| Workspace / Shell | `agent_product/src/tools.cj`、`agent_product/src/local_infrastructure.cj`、`extensions/workspace_search_extension`、`extensions/workspace_write_extension` | 文件身份/边界、冲突校验、原子变更、进程/PTY/网络规则 | 工具表达和算法外迁；宿主保留通用原语；无 Shell 时安装器仍可工作 |
| Program / file plans | [agent_product/src/program_worker.cj (historical #43)](https://github.com/lIlIIlIll/Axyndra/blob/4d88fa6072f7176a6d236a1cb39b33529d5b609d/agent_product/src/program_worker.cj)、[agent_product/src/program_runtime.cj (historical #43)](https://github.com/lIlIIlIll/Axyndra/blob/4d88fa6072f7176a6d236a1cb39b33529d5b609d/agent_product/src/program_runtime.cj)、`agent_product/src/file_application_plan.cj` | #43 派生 Operation、父预算、只读限制、精确计划审批 | worker/语言适配/工具包装外迁，不能另建执行权威或扩张可写 PTC |
| Skills / context | `agent_skills`、`plugins/skills/src/discovery.cj`、`agent_product/src/prompt_runtime.cj`、`tool_runtime/src/context.cj` | 来源信任、有界发现、惰性引用、固定内容；工具上下文已换为不可变通用投影 | `SkillStackSnapshot` 仍进入 Core、runtime、store 和 embed；完整上下文插件化仍须接入唯一版本体系 |
| Memory / compaction | [agent_product/src/memory_tools.cj (historical #43)](https://github.com/lIlIIlIll/Axyndra/blob/4d88fa6072f7176a6d236a1cb39b33529d5b609d/agent_product/src/memory_tools.cj)、`agent_core/src/context.cj`、`agent_runtime` | canonical 原始事实、合法切点、预算和 checkpoint | 抽取、检索/embedding、候选摘要和模型建议进入策略插件 |
| Workflow | [agent_product/src/todo_tool.cj (historical #43)](https://github.com/lIlIIlIll/Axyndra/blob/4d88fa6072f7176a6d236a1cb39b33529d5b609d/agent_product/src/todo_tool.cj)、[agent_product/src/goal_runtime.cj (historical #43)](https://github.com/lIlIIlIll/Axyndra/blob/4d88fa6072f7176a6d236a1cb39b33529d5b609d/agent_product/src/goal_runtime.cj)、`agent_product/src/task_product.cj`、`task_runtime` | 子运行准入、审批、共享预算、父子取消 | Planning/Todo/Goal/Subagent 工具、角色和路由外迁 |
| Model | `model_adapters`、`agent_product/src/product.cj` | `ModelPort`、唯一 AgentCore/Attempt、预算、冻结输入、结果验证 | wire/provider/auth/discovery 外迁；缺模型仍可启动管理；不能隐藏重试 |

### 配置、命令与数据

| 表面 | 当前格式或位置 | 切换要求 |
| --- | --- | --- |
| 主配置 | `agent_product/src/config.cj` 检查 `schema_version: 1`；包含 shell、model、compaction 等业务配置 | 插件配置独立命名空间；宿主政策和 grant 独立；未知字段/旧版本显式拒绝或按已定义迁移 |
| MCP 配置 / 生态声明 | [agent_product/src/mcp_runtime.cj (historical #43)](https://github.com/lIlIIlIll/Axyndra/blob/4d88fa6072f7176a6d236a1cb39b33529d5b609d/agent_product/src/mcp_runtime.cj)、包 descriptor 的 MCP component | 解析/适配进入 MCP 组件；静态 inspect/help 不启动服务；缺插件明确报告 |
| 插件 HTTP 配置 | `agent_product/src/plugin_http_configuration.cj`；按包身份/摘要冻结非秘密配置、精确请求 grant 与 opaque credential refs | 新原生 HTTP 插件不读取旧 provider 环境变量；缺少匹配配置显式拒绝；更新摘要不继承旧授权，回滚不自动启用 |
| CLI / slash | 通用 `agent_app/src/tools_cli.cj`、`agent_app/src/plugin_cli.cj`；仍有 `mcp-server` 和 `/mcp` 业务入口 | `tools inspect/invoke` 与 `plugin` 管理不依赖模型调用；专属 `search`/`q` 已退役；其余业务命令须来自有类型贡献和前端能力协商 |
| 插件安装事实 | 用户/工作区 `plugins/lock.jsonl`、`plugins/packages` 和版本历史，由 `ProductPluginRuntime` 管理 | 复用来源/内容锁；未知版本不能覆盖；升级中断保留旧代；回滚不恢复撤销授权 |
| SQLite | `agent_store/src/database.cj` 的当前 schema v26 和 `agent_store/src/schema.cj` 的迁移 | 必要新字段由同一 Store 事务管理；不创建插件事实数据库；写入前版本检查、备份、恢复证据 |
| 不可变文件计划 | `agent_product/src/file_application_plan.cj`、`agent_product/src/plugin_file_plan_service.cj` | Program plan/v1 保留，插件使用显式 plan/v2 来源；历史 artifact bytes 保留可读取。apply/recover 必须有真实生成/恢复的 Operation、Receipt、已提交 ToolResult 证明，无证明旧计划显式拒绝执行 |
| Run / Operation / Receipt / context | `agent_store`、`agent_runtime`、`agent_core`、`tool_runtime` | 仍由可信宿主持有；新增插件版本/来源/挂起关联不产生第二条提交链 |
| 历史、fork、GC | 既有 continuation、artifact、plugin 历史与检查入口 | 活动 Attempt/Prepared Operation/保留历史引用的内容禁止覆盖或回收；缺版本可检视、不可冒充恢复 |
| 发行 | `scripts/package_candidate.sh`、`scripts/package_readiness_gate.sh` | Minimal/Coding/Full 锁定清单和独立产物；随附、默认启用、核心必需分别表达 |

起始 A0 盘点本身不修改格式；后续文件计划新增 v2 及旧 v1 读取/执行拒绝边界，
不改 SQLite schema v26。完整插件配置/存储切换、升级中断、备份和回滚验证仍由
A7-02 交付，不能据此宣称全部旧格式迁移已完成。

## 依赖基线与门禁

起始工作树包含 41 个本地 package（包括 workspace 外、通过 path 依赖引用的 vendor
package）。MCP adapter、独立 AST 与 Web 插件各新增一个本地 package，删除旧静态
AST 与 Web package、再加入独立 MCP Client/Server package 后当前图为 44 项。审核基线现包含 126 项仍存
Optional capability 耦合；完整依赖图和分类计数由 `--report` 输出。计数是结构测量，
不是缺陷严重性、二进制大小或性能指标。

当前图包括 workspace/path 可达的 40 个 package，以及通过 `plugins/*/cjpm.toml`
发现的独立 `ast_plugin`、`web_search_plugin`、`mcp_client_plugin` 和
`mcp_server_plugin`。独立插件不加入宿主 workspace，但必须在 optional policy
显式分类；新增未分类插件会拒绝通过。宿主未来通过任何 path alias 链接这些插件
会形成新的违规边，而不能因插件曾不在 workspace 中绕过棘轮。插件自身另行构建/打包
和运行契约；删除旧静态 AST 编辑 package 时同步收紧 5 条旧允许边，删除 Web 静态
package 和专属 search CLI 时再收紧 6 条。已退役的 `web_search_extension` 仍保留在
禁止依赖分类中，防止恢复旧宿主装配；没有为通过门禁而删除其禁止规则。

策略和审核基线分别位于 `scripts/plugin_boundary_policy.json`、
`scripts/plugin_boundary_baseline.json`。基线 SHA 固定为上文起始提交；
`reviewed_adjustments` 明确记录 MCP adapter 边的迁移、直接 Skill 边的移除，以及
扫描器纳入既有 LSP/DAP alias import 的调整，以及旧静态 AST/Web 依赖和 search CLI 的删除。
独立插件分类和目录发现不增加任何允许违规项。当前默认棘轮与 15 项变异测试通过，
严格 `--minimal --host-package agent_app` 实际拒绝 84 条仍存耦合，不含已外迁的 AST/Web。

```sh
python3 scripts/plugin_boundary_gate_test.py
python3 scripts/plugin_boundary_gate.py --report target/plugin-boundaries.json
python3 scripts/plugin_boundary_gate.py --minimal --host-package agent_app
```

默认命令是迁移棘轮：允许明确记录的旧依赖，拒绝新增能力依赖；已删除的边无需
保留，也不要求为通过门禁而加回。移除依赖后应同步缩减审核基线，禁止通过重新
生成基线掩盖新增业务耦合。严格 `--minimal` 不接受任何基线豁免；在起始产品图上
**预期失败**，例如 `agent_app -> agent_mcp` 和
`agent_app -> agent_product -> lsp4cj`。`scripts/architecture_gate.sh` 执行棘轮及其
变异测试，并不宣称 Minimal 已通过。

门禁检查传递依赖、path 别名的真实 package identity、目标平台 dependencies、
生产源码 import（包括未写入 manifest 的能力导入），并拒绝缺失的本地依赖或宿主
根。测试文件、字符串 fixture 和注释不计为生产 import。它不是完整 Cangjie 语义
分析器，不能检测复制后改名的业务实现，也不检查机器码。传递图递归解析本地 path
依赖；外部 Git 依赖按 manifest 声明作为叶节点，不下载并解析其内部依赖。远程包
改用未知别名、外部依赖内容和最终链接产物需要额外审计。最终 Minimal 验收仍须：

1. 在隔离的 staging checkout 中排除能力源码、插件产物及其专属依赖。
2. 清理构建缓存，用发行版的宿主根执行真实构建，保存构建依赖及链接/产物清单。
3. 从无 checkout/SDK 的安装目录运行静态 help、插件管理、历史检视及缺模型诊断。
4. 固定该宿主二进制的摘要，安装独立 MCP/另一个业务插件后运行真实工作流，
   验证宿主摘要未变化；禁用/卸载后检查连接、注册和新准入均已停止。

## 行为基线与已有验证入口

这些入口用于迁移前后的同条件对照；下表列出覆盖意图，不代表本次重新执行结果。
保留已有轨迹与安全语义，已知缺陷不能仅因出现在基线中就固化为兼容要求。

| 要保留的行为 | 当前入口 | 迁移后的新增证据 |
| --- | --- | --- |
| canonical 轨迹 / 准入 / 授权 / 提交 | `scripts/vnext_contract_gate.py`；`support_tests/agent_core_contract`、`support_tests/tool_runtime_contract`、`support_tests/operation_domain_vnext_contract` | 相同真实产品入口调用外部插件；故障后仅一份 canonical 事实 |
| 受控 JS、派生调用、取消、计划应用 | `support_tests/product_thread_runtime_contract`、`support_tests/extension_runtime_contract` | 原生/JS 同一边界；初始化越权、迟到结果、未知效果、单槽嵌套 |
| MCP 协议 / 本地服务 | `scripts/mcp_conformance_gate.sh`、`scripts/mcp_conformance_manifest_gate.sh` | 外置 Client/Server 的 stdio/HTTP、审批、取消和支持矩阵 |
| 默认产品流程 / 进程 broker | `scripts/product_regression_gate.sh`、`support_tests/frontend_regressions`、`support_tests/process_broker_blackbox` | Coding 从清单装配；空插件目录管理/历史仍可用 |
| 已有包导入 / 更新 / 隔离 | `agent_product/src/plugin_runtime_test.cj`、`agent_extension_runtime/src/plugin_package_test.cj` | 组件依赖、半注册回滚、权限撤销、旧版本保留 |
| 历史 / 恢复 / fork / 上下文 | `support_tests/agent_store_contract`、`support_tests/thread_runtime_integration_contract`、`support_tests/context_projector_vnext_contract`、`support_tests/child_run_vnext_contract` | 固定贡献/schema/内容，缺插件仍可检视，fork 不共享可变实例 |
| 干净打包 / 冷启动 | `scripts/package_readiness_gate.sh`、`scripts/cold_start_gate.py`、`scripts/release_gate.sh` | 宿主移除能力源码后可构建；独立插件安装不重编译宿主 |
| 性能 | `support_tests/plugin_performance_baseline/check.py` | 同机器/工具链/样本，记录无插件启动、首次激活、热调用、负载、RSS、取消/回收的 P50/P95；单独测 IPC/流事件开销 |

初始验证：Python 3.14.3 下新增门禁 13 项测试通过；迁移棘轮通过并明确报告 137 项
仍存基线耦合。Cangjie 构建、运行行为和性能需要由实际执行记录补充，不能从这两个
Python 结果推出。

### 已实施的工具上下文边界

`agent_domain/src/invocation_context.cj` 提供 provider-neutral 的贡献/资源引用视图：
owner 与 contribution ID、固定 locator、已加载内容及其 digest、明确的
`UserSelected` / `UntrustedData` 信任级别。它不含 Skill 名称、触发规则、能力 grant
或执行接口。集合在构造和访问时防止调用方数组替换。

`agent_skills/src/invocation_context.cj` 只投影已经冻结的 Run Skill 输入，不发现文件
也不读取惰性引用。`ToolInvocationContext` 的 `skills` 字段改为 `contextProjection`，
`tool_runtime` 删除直接 `agent_skills` import/manifest 依赖。Core 启动/恢复和受控
直接调用构造该投影；Program 和插件派生调用传递同一投影。Product Skill 适配器
按 namespace 和声明引用读取，保持路径检查，优先返回已加载固定内容。

这是一份现有输入的只读投影，没有新数据库、registry 或上下文版本。未加载的
locator 固定不等于远端/可变文件字节固定；读取仍通过受控 loader。Core/runtime/store
的 Skill 数据及工具 runtime 经 `agent_runtime` 的间接依赖尚存，因此本项不能宣称
Skills 已成为可卸载插件。相关新增验证位于既有 `support_tests/skill_runtime_vnext_contract`、
`support_tests/tool_runtime_contract` 和 `agent_product/src/skill_reference_discovery_test.cj`；
2026-10-04 本轮已实际运行并通过：

```sh
cd support_tests/skill_runtime_vnext_contract
../../scripts/pinned_cangjie cjpm run
cd ../tool_runtime_contract
../../scripts/pinned_cangjie cjpm run
cd ../agent_core_contract
../../scripts/pinned_cangjie cjpm run
```

参考环境：WSL Arch Linux x86_64、kernel 6.6.87.2、Cangjie/cjpm STS 1.1.3、
校验和固定的 stdx 1.1.3.1、Clang 22.1.8。测试使用任务独立的临时目录和 SDK cache；
依赖可能复用 WSL 用户缓存，未证明干净依赖缓存构建。这些目录不是发行要求。
Skill 契约包含投影无额外读取、明确信任、固定引用、
已加载内容 digest 与重复 preload 拒绝；Tool 契约包含非 Skill provider、集合不可变、
重复 identity 拒绝和不增加 capability。Core 契约还验证无效重复内容在 Run 准入和
模型执行之前返回 `context.snapshot_invalid`，不留下 Run/Attempt/event。
同一工作树的 Product 测试二进制构建后，本轮还实际执行：

```sh
scripts/pinned_cangjie cjpm test -m agent_product --skip-build \
  --filter 'ProductSkillDiscoveryBoundaryTests.*' --parallel 1 \
  --timeout-each=60s --no-color --no-progress
```

结果为 5 项通过、0 error、0 failed，另外 90 项被过滤；这是定向测试，不是全部
Product 单测通过。首次运行需先构建测试二进制或移除 `--skip-build`。新增三项验证：
固定 locator 且惰性受控读取、预加载内容不被文件系统替换，以及无效输入在真实
Product 入口拒绝且数据库没有相应 Thread/Run。完整发行矩阵仍须另行验证。

### 已实施的维护执行边界

`agent_product/src/plugin_maintenance.cj` 接收既有维护入口冻结、授权后的 canonical
计划，直接通过 `LocalProcessPort` 和 `processOperations` 执行宿主生成的 Git/npm
命令。它校验计划与上下文的 staging root，只挂载计划批准的工作区只读目录，使用
计划中的显式网络政策、调用预算和关联取消，并返回同一 Operation 的结果/Receipt。
`controlled_process_policy.cj` 与普通 Shell 复用原有网络限制，没有扩大网络权限。
维护 descriptor 的实现版本和 fingerprint 升至 v3，旧冻结计划不能静默替换执行器。

维护执行固定使用 `/bin/bash --noprofile --norc -c`，禁止 PTY/异步，超时有上限；
不实例化 `BashTool`，不进入 `executeShell` 的会话常驻 shell。系统 Bash/Git/npm
仍是该获取方式的运行依赖；共享进程辅助类仍在产品 `tools.cj`，Shell 业务工具
尚未外迁，构建产物并未排除其源码。这一步不证明完整无插件
发行版自举，也不声称已完成 A1-04 或 A4-02。

`support_tests/product_thread_runtime_contract` 的 `--plugin-acquisition-contract`
范围在真实 Product 中移除 `bash` 和 `bash_readonly` 注册，再通过本地 Git 仓库和
loopback npm registry 获取真正的原生 `hello` 命令插件。测试保留固定 revision/
version、依赖/SRI/内容锁、审批、网络 Receipt、离线快照复用、禁用导入、启用、
失败更新清理和旧版本保持；失败更新前后均调用原生命令。原生 fixture 使用
`AXYNDRA_NATIVE_PLUGIN_FIXTURE` 指定的产物，未提供时从仓库 C 示例实际构建。
该获取契约保留测试用签名 verifier 和非空 fixture 签名；实际内容摘要由导入器
计算。它验证获取/授权/执行流程，不构成生产签名算法的验证证据。

### Foundation 检查点验证记录

以下结果来自 2026-10-04 已冻结的 Foundation 检查点，先于后续 Direct 根准入和
AST 外迁更改；不能作为后续源码的验证结论。Cangjie 项使用上文 WSL 工具链。所有命令均从
仓库根或注明的 package 目录执行；环境按 `scripts/ci_toolchain.env` 固定 SDK/stdx。
Product 原生测试先运行 `python3 support_tests/native_plugin_fixture/check.py`，并将
`AXYNDRA_NATIVE_PLUGIN_FIXTURE` 与 `AXYNDRA_NATIVE_TOOL_PLUGIN_FIXTURE` 指向生成的
`target/native-plugin`、`target/tool/native-plugin-tool`。`--skip-build` 只在同一工作树
测试二进制已构建后使用。

| 范围 | 实际命令 / 筛选 | 结果及覆盖边界 |
| --- | --- | --- |
| 依赖门禁 | `python3 scripts/plugin_boundary_gate_test.py`；`python3 scripts/plugin_boundary_gate.py` | 13 项变异测试通过；42 package / 137 项审核基线耦合，棘轮通过 |
| 文档 | `python3 scripts/docs_gate.py` | 16 Markdown / 39 workspace package，通过 |
| 工作区清理与应用构建 | `scripts/pinned_cangjie cjpm clean`；`scripts/pinned_cangjie cjpm check`；`scripts/pinned_cangjie cjpm build -m agent_app -o agent_app` | 官方 clean 后检查和应用构建实际通过；清除 MCP adapter 移动前的旧生成物，没有生产绕过；这不代表依赖缓存隔离或已安装发行版验收 |
| 完整 Product 单元测试 | 同一编译二进制 `scripts/pinned_cangjie target/release/unittest_bin/agent_product --filter=<exact_case> --parallel=1 --timeout-each=60s --no-color --no-progress`，逐例独立进程运行 dry-run 枚举的全部 95 项 | 最终 **95/95 通过，0 failed/error/skipped**；覆盖最终修复后的 Codex/legacy metadata 断言。下列 Product 定向结果属于这 95 项，不另行相加 |
| 进程契约与包解析 | `scripts/pinned_cangjie cjpm test -m agent_extension_runtime --no-color` | 实际 17 项通过，0 skipped/error/failed；含 6 项原生契约和 11 项既有包解析 |
| 原生 Product | `scripts/pinned_cangjie cjpm test -m agent_product --filter 'NativePluginContractTests.*' --parallel 1 --timeout-each=60s --no-color --no-progress` | 实际 5 项通过；真实独立进程工具/命令、声明不匹配、实例/权限域绑定 |
| 旧原生格式 | 上述 Product 命令的筛选改为 `PluginRuntimeContractTests.legacyAxyndraSnapshotRejectsExecutionAndPreservesInstalledData` | 实际 1 项通过；不是零匹配；旧内容仍可检视且执行明确拒绝 |
| 工具上下文 | 上文 Skill/Core/Tool 契约及 `ProductSkillDiscoveryBoundaryTests.*` | 三个可执行契约通过；Product 实际 5 项通过，0 error/failed |
| 类型化来源 | 在 `support_tests/tool_runtime_contract` 执行 `../../scripts/pinned_cangjie cjpm run` | 实际通过；Direct/Committed/Derived、审批后保留、根证据/epoch/handoff/准入检查；不证明 Direct broker 已支持 |
| Pi / native 派生 broker | 在 `support_tests/product_thread_runtime_contract` 构建后执行 `../../scripts/pinned_cangjie target/release/bin/main --javascript-service-broker-contract` | 实际通过，两条真实进程路径均检查模型提交父 Operation、派生来源/Receipt、单槽调度及只读无网络约束 |
| 维护安全回归 | Product 筛选分别为 `PluginRuntimeContractTests.restrictedPluginAcquisitionUsesEndpointBoundMediation`、`PluginRuntimeContractTests.remotePluginAcquisitionCannotReadWorkspaceOrUseLocalDependencies` | 实际各 1 项通过；显式 endpoint mediation、远程获取无工作区读取/本地依赖权限 |
| 无 Shell 注册的维护获取 | 在 `support_tests/product_thread_runtime_contract` 构建后执行 `../../scripts/pinned_cangjie target/release/bin/main --plugin-acquisition-contract` | 最终实际通过；移除两项 Shell 注册后，真实 Git/npm 获取、原生命令执行、来源锁/Receipt、失败更新和 staging 清理全部通过 |
| 完整 Product Thread 契约 | 在上述 package 执行 `../../scripts/pinned_cangjie cjpm build`，再执行 `../../scripts/pinned_cangjie target/release/bin/main`（无筛选参数） | 最终实际通过、exit 0；Program/类型化 broker/原生审批与 Receipt 路径实际执行；这仍不是全部发行矩阵 |
| Thread 取消竞态 | 在 `support_tests/thread_runtime_integration_contract` 执行 `../../scripts/pinned_cangjie cjpm run` | 最终实际通过；finish、child token、resolveOperation 校验预期 Run/epoch，旧调用不能结算后续 Run |
| MCP adapter 提取 | 在 [support_tests/mcp_extension_contract (historical source)](https://github.com/lIlIIlIll/Axyndra/blob/4d88fa6072f7176a6d236a1cb39b33529d5b609d/support_tests/mcp_extension_contract/src/main.cj) 执行 `../../scripts/pinned_cangjie cjpm run` | 实际通过；只证明已提取的编译 adapter 契约，不证明外置 MCP 插件 |

完整 Product 汇总逐一核对 95 个不同用例与 cjpm dry-run 清单；每个独立进程的
输出为 `TOTAL 95 / PASSED 1 / SKIPPED 94`，汇总时只计其指定用例，不能把被筛掉的
用例当作通过。测试二进制 SHA-256 为
`f0c97f63e3c3a2706155d5aa379b0eb21349172346e85d53fec89de95d97a939`；
验证证据包的 `full-product-units-direct/summary.json` 列出命令和全部逐例日志。

尚未完成完整 release gate、source-removed Minimal 构建、clean-env 打包和同条件
全套性能对比。不能把定向测试之外的过滤用例算作通过，也不能把既有缓存下的构建
称为干净环境验收。

### Foundation 同环境性能对照

起始 SHA 对照上述 Foundation 冻结产物，两版均通过既有采集器预算。应用摘要分别为
`123771540a83621ef1efedfebf53ee27bcd2a2e8832e406c81e7906fa7f0fe70` 与
`65da4a50acf2414dadb625991cf73ae6111254be2260d8e8138390efb6e94c27`，应用字节数分别
为 49,747,737 与 50,063,129；并非插件化后缩小产物的证明。

| 指标 | 每版 N | 起始 P50 / P95 | Foundation P50 / P95 |
| --- | --- | --- | --- |
| Full Product fixture `/help`，ms | 20 | 140.952 / 155.232 | 140.528 / 150.701 |
| Full Product fixture 静态 inspect，ms | 20 | 464.218 / 514.849 | 445.481 / 494.436 |
| `/help` 采样峰值 RSS，bytes | 20 | 140902400 / 141393920 | 141557760 / 142049280 |
| inspect 采样峰值 RSS，bytes | 20 | 140902400 / 141557760 | 141557760 / 142213120 |
| 既有 Pi host 冷启动，ms | 12 | 40.970 / 168.351 | 47.343 / 51.027 |
| 既有 Pi host 首次调用，ms | 12 | 9.521 / 10.960 | 9.569 / 10.404 |
| 既有 Pi host steady IPC，ms | 240 | 10.097 / 10.178 | 10.132 / 10.254 |
| 既有 Pi host 调用后 RSS，bytes | 12 | 26091520 / 37072896 | 26193920 / 36978688 |
| 既有 Pi host 取消调用耗时，ms | 12 | 125.233 / 126.578 | 124.926 / 127.479 |

两版使用同一初始为空的临时工作区，各自使用新的 AXYNDRA_HOME，随后在每版 40 次
Product 调用中复用 settings/state；未安装或启用插件。应用已打包，运行时取消
LD_LIBRARY_PATH。原采集器循环、命令、解析和预算保持相同，只有运行 benchmark 的
`cjpm run` 被替换为同版本冻结二进制，避免后续源码变动重编译已测对象。

这属于观察对照，不主张因果优化：起始版本先运行，未清 OS cache 或随机化顺序。
`plugins_disabled` 是 Full Product fixture 的既有 profile 名，不证明 Minimal。
Pi 指标使用直接启动进程的 RecordingLauncher，不代表 Product 隔离 launcher 或
新增 native/AST 服务。取消耗时包括约 100 ms 的触发等待，在 invoke 返回时结束，
不含随后 host.close 的完整回收；Pi RSS 是调用后 VmRSS，Product RSS 以约 1 ms
轮询峰值。原采集器只保存 N/P50/P95，未导出每个样本。未覆盖流事件、负载大小、并发、
跨平台和完整回收矩阵，亦不适用于后续迁移源码。证据汇总为验证包的
`performance-summary.json`，其中包含产物清单摘要、环境和初始目录状态。

### Direct / AST 查询检查点

`plugins/ast` 将查询 schema、目标/glob 解析、引擎调用、分页、诊断与结果渲染移入
独立可执行包；[构建及安装说明](../plugins/ast/README.md) 固定 ast-grep 0.45.3
的 engine/许可证摘要，打包相对 RPATH 的运行库。Product 删除 AstGrepTool 和
ProductExtensionOperationHost 的 ast_grep 分支；共享的纯 hashline tag 算法移入
`agent_domain/src/content_tag.cj`，保留既有输出语义，不引入新执行权威。

插件端点请求通用 `process.readonly`，由宿主将包内 worker 固定在批准工作区、
只读文件系统及 Denied 网络下运行，沿父预算/取消和子 Operation/Receipt 执行。
宿主服务不识别 AST 业务。该查询检查点的 AST 编辑及网页搜索仍在宿主，不能把查询迁移视为 A3-01
全部完成。独立包已实际编译、打包，并通过 `python3 plugins/ast/check.py --package
<artifact>` 的 16 项真实引擎/worker/协议测试；其中协议 mock 的 receipt 检查不等于
Product durable Receipt 验证。包内入口 SHA-256 为
`960c62787b17cc313c27a775f6c14f4425295a558dd663443227dd2f3ec17d1f`，包含 8 个非系统
运行库，取消 SDK/LD_LIBRARY_PATH 后运行，ldd 仅解析包内及系统库。引擎固定字节和
许可证经锁摘要校验；本次包总大小为 96,202,881 bytes。错误诊断也限制为 4096 bytes，
测试包含合法有界输入中的超长未知键，避免失败结果绕过正常输出上限。

`--ast-plugin-contract` 的真实 Product 隔离/准入/执行链已实际通过，日志
`phase2/product-thread-ast.log` 记录 `independent AST plugin contract passed`。
该契约在 Shell 与旧 AST edit 注册均不存在时，执行导入/启用、真实结构查询与分页、
空结果、路径逃逸和缺少读取授权拒绝，并从现有 SQLite 核验 Direct 父、受控进程子
Operation/Receipt、Denied 网络、两次调用预算及无伪造 Decision，最后禁用且不恢复
宿主查询 fallback。独立包构建/协议证据为 `phase2/ast-package-build.log` 与
`phase2/ast-package-check.log`；上面的 Foundation 通过记录不覆盖本批。

Direct/受控进程新增验证已有以下实际结果，均以本批重编产物为准：

| 范围 | 结果 | 边界 |
| --- | --- | --- |
| `support_tests/tool_runtime_contract` | 实际通过 | 密封 Direct 来源、派生准入、epoch/来源核验和隐藏 host service 不能通过普通工具调用获取 |
| `support_tests/agent_store_contract` | 重编后实际二进制通过 | 持久化 Direct 根与现有 Item/Run/Operation 事实绑定；不伪造模型 Decision；不放宽派生写权限 |
| `PluginReadOnlyProcessServiceTests.*` | **4/4 通过**；总 99 项中其余 95 被筛选 | 真原生包 worker、移除 Shell 后读取/Receipt、拒绝写入/系统可执行文件/伪造包身份、输出截断失败、禁用取消活动 worker |
| 完整 Product 单元测试 | **99/99 通过，0 failed/error/skipped** | 本批同一重编二进制逐例独立进程运行；清单与 dry-run 枚举一致，涵盖上面的 4 项新服务用例，不另外相加 |
| Core / Thread Runtime | 两个实际可执行契约均通过 | 当前 Direct 来源更改后的 Core 回归，以及 Run/epoch/取消/一致性约束 |
| Extension Runtime 契约 | 实际可执行契约通过 | 旧编译 AST adapter 只保留 ast_edit；插件查询未重新加入默认业务注册 |
| Testkit / 旧 AST adapter | Testkit 实际可执行契约通过；AST adapter 单元 **2/2 通过** | 旧 SDK 只保留尚未迁出的 ast_edit 契约；不把 mock 的宿主调用算作独立查询插件验证 |
| 独立 AST Product 查询 | 实际契约通过 | 真正安装包、隔离 worker、Direct 来源、单槽预算、数据库子 Receipt 与禁用后的无默认 fallback |

相应证据分别为 `phase2/tool_runtime_contract-direct-final.log`、
`phase2/agent_store_contract-direct-final.log` 和 `phase2/product-process-service-tests.log`。
完整 99 项证据独立记录于 `phase2/full-product-units/summary.json`，二进制 SHA-256 为
`bb07dec2ef8a2b2aab355fedf603147af30266cd7e46fa232d4a080784ecc976`。不是把 Foundation
的 95 项与新增 4 项相加得到通过结论。Core/Thread 日志为
`phase2/agent_core_contract.log` 与 `phase2/thread_runtime_integration_contract.log`；
Extension Runtime 为 `phase2/extension_runtime_contract.log`，Testkit 与旧 AST adapter
分别为 `phase2/testkit_extension_contract.log`、`phase2/ast-extension-tests.log`。

本检查点仍有明确未通过项：完整 `product_contract` 在 `missing tool schema:
ast_edit` 处停止，环境没有旧静态编辑适配器依赖的系统 ast-grep；日志为
`phase2/product_contract-nativecwd.log`。`product_rpc_contract` 缺少预期 task lifecycle
及 progress 事件而失败，见 `phase2/product_rpc_contract.log`；后续查明断言在约一秒
处提前结束等待，完整终态帧中事件齐全。该历史运行仍记失败，后续候选改为有界等待
实际 prompt 终态再检查事件顺序。broker scope 当时在 Direct 预算不足分支的
known-failed Receipt 断言失败，见 `phase2/product-thread-broker.log`；后续查明断言
混淆了 Operation 已 committed 与 Receipt outcome failed 两个字段。这处断言修正
随后暴露真实持久化缺陷：Prepared 阶段预算失败未原子提交失败 Receipt/ToolResult，
finish 将原错误覆盖为 `thread.incomplete_tool_round`；不能将后续失败归因于测试。
不能用独立 AST scope 或 99 个 Product 单元通过
覆盖这些失败，也不声称本批完整 Product Thread / release gate 已通过。

本批依赖门禁新增独立包发现/显式分类，以及模拟宿主通过 alias 链接 ast_plugin 的
拒绝测试：现有 15 项变异测试全部通过，默认棘轮在 43 packages / 137 旧违规下通过。
`--minimal --host-package agent_app` 仍按预期拒绝 91 项既有能力耦合，不包含 AST 查询
插件边。WSL 下完整 `bash scripts/architecture_gate.sh` 实际通过，涵盖文档、工作区
环路/反向 UI 依赖、依赖 pin、库边界、SDK 兼容及包清单；它仍是结构验收，不能代替
上述 Product 执行契约，也不消除尚未通过的范围。

### AST 1.1 编辑迁移检查点

独立 AST 包新增只读 rewrite worker 和串行 `file.plan.propose` 请求。旧宿主 AST
编辑器、私有 pending 队列、`xd://resolve/reject` 分支及静态 AST package 已删除，
默认产品不再注册 AST 工具。查询检查点中依赖系统编辑 engine 的旧合同已迁移到
实际插件场景；不能将删除旧失败路径本身当作新行为通过。

编辑 worker 只产生 schema/operations，最多 32 个文件、1000 处替换，编码 proposal
及完整结果各自不超过 64 KiB；拒绝重叠、源文本变化和路径逃逸，不截断提案。
宿主绑定真正的插件/父子 Operation 来源并存储 plan/v2，不伪造 Program，不新增
pending Store。独立 `apply_file_plan` 继续要求写入授权及精确一次审批，沿既有逐文件
条件原子发布、partial/unknown 和恢复语义执行，不声称多文件事务原子性。

计划来源验证还读取现有持久化生成 child Receipt 与成功提交的父 ToolResult。
恢复 continuation 保留原插件来源并绑定新的恢复 Operation/Run 及其结果；孤儿、
取消或未知生成的 artifact 不能仅凭摘要申请写入。Program v1 也核验真实 Program
或恢复结果，防止伪装旧格式绕过证明。旧 artifact 内容仍保留可读；缺少证明时
apply/recover 明确拒绝，不静默重写历史 bytes。新增宿主服务单元实际 **2/2 通过**，
包含伪造来源、孤儿 artifact 以及降级为 v1 后的执行拒绝，日志为
`phase3/product-file-plan-tests.log`；后续完整 Product 单元结果见下文。
apply/recover 的 implementation version 和 fingerprint 同时升为 v2；旧 artifact
仍可读取，但旧 PreparedInvocation 不能复用新执行器，必须重新 prepare 并接受来源验证。
旧 v1 recovery 曾允许从仅格式合法、尚未证明 Program 来源的 artifact 生成 continuation，
因此其成功 Receipt/ToolResult 本身也不能证明原始来源。恢复证明现在必须绑定 v2
recovery implementation fingerprint；旧 v1 recovery continuation 保留字节和历史读取，
但 apply/recover 明确返回 `application_plan.origin_uncommitted`。具有真实源摘要及生成
结果证明的原始 Program v1 计划仍可重新准备审批或由新执行器恢复。该 breaking 边界的
真实 SQLite 旧 Receipt/ToolResult 反例已纳入最终 102 项单元并实际通过。

本阶段 RPC 改为共享 30 秒 deadline，等待实际终态后检查完整事件及其先后关系，
真实契约已重编通过，日志为 `phase3/product_rpc_contract.log`；查询检查点的旧失败
记录保留。早期 Product 单元 101/101 的二进制先于 Store 预算修复；修复后最终
**102/102** 逐例独立进程实跑全部通过，0 失败/错误/跳过，枚举与 dry-run 一致。
证据为 `phase3/full-product-units-final/summary.json`，二进制 SHA-256 为
`f829b6e3c3ad6d53994227b676302d1e81139dd0f4ad023315d50efd4cb69cfb`。
Store 现已限定允许
Prepared+Failed 且 stage=prepared 的原子提交，同时在事务内验证活动 Run/epoch、
ToolCall 和尚未 handoff；不允许 Prepared+Completed/Unknown。新增 Store 正反例
已实际通过，真实 Pi/native/Direct broker 预算、失败子调用、Receipt 及取消场景重编
运行通过，日志为 `phase3/agent_store_contract-final.log` 与
`phase3/product-thread-broker.log`。同一最终二进制的完整无筛选 Product Thread 契约
也已通过，覆盖 AST 查询/编辑、Pi/native/Direct broker、插件获取和真实 Program；
日志 `phase3/product-thread-full.log` 以 `product Thread Runtime contract passed`
结束，二进制 SHA-256 为
`db3a25e428b861d7e0e8d9fb8758c89fe9faf3ee7abe2915618e29e684139bbc`。
执行正式 `cjpm clean` 后的 `cjpm check` 及应用构建均通过，日志分别为
`phase3/cjpm-clean.log`、`phase3/cjpm-check.log` 和 `phase3/application-build.log`；
最终应用 SHA-256 为
`7430309a998a6de3a85c842e8e69af7bc01330913b31bced6e0f8f0466ae4e1c`。
这不证明干净系统依赖缓存或无 SDK 安装场景。完整旧 Product 契约最终也实际通过，
`phase3/product_contract.log` 以 `product contract passed` 结束；真实 Pyright/LSP、
Bun/Ruby eval、进程输出/取消及应用授权场景没有跳过。工具链仍为 Cangjie 1.1.3、
stdx **1.1.3.1**（以包内版本为准）及 Clang 22.1.8。

该合同还校正了一处起始版本已有的测试矛盾：生产取消策略立即强制终止，而旧 fixture
期待 TERM handler 输出。生产取消和沙箱未改；测试现验证 ready 后取消导致非零退出、
无超时、无残留活动进程、三秒内完成且没有 TERM marker，并保留逃逸/多线程后代
heartbeat 停止验证。定向及完整合同实际通过，不能将此次 fixture 校正描述为新增
插件取消生产修复。以上全部通过只覆盖本检查点列出的命令和环境，不等于 #45 的
完整故障、平台、性能或 Minimal/Coding/Full 发行验收。

编辑候选版本为 1.1.0，与查询检查点 1.0.0 的独立产物区分。1.1.0 包独立构建/打包及
26 项真实 worker/协议测试已经通过，最终候选为 `ast-package-phase3-2`，日志为
`phase3/ast-package-build-2.log`、`phase3/ast-package-check-2.log`。新增
`--ast-edit-plugin-contract` 覆盖实际提案来源、两个 child Receipt、三调用/单槽预算、
伪造 artifact、拒绝/取消/冲突、恢复 continuation 和批准应用。当前源码与 1.1.0 包的
真实宿主 scope 已通过，日志 `phase3/product-thread-ast-edit.log` 记录
`independent AST edit plugin contract passed`：先以仅只读插件 authority 生成提案，
重新打开同一持久化状态后按 AlwaysAsk 策略独立批准写入；精确伪造来源拒绝发生在
Operation/handoff 前，并保留原字节。基础静态复核已通过：38 workspace packages、42 本地图节点、132 条存量违规，
15 项依赖变异测试与库边界检查通过；严格 Minimal 仍因 88 条既有能力耦合拒绝，
删除 AST 不等于 Minimal 已完成。这些记录也不替代完整产品及发行矩阵。
同一最终宿主与 1.1.0 包的查询 scope 也已实际重验通过，日志为
`phase3/product-thread-ast-query.log`。独立发行 tar.gz 为 21,075,950 bytes，SHA-256
`bec6a6d643f0ca4fff26b4466cda75da724e4520ef8b8aa759f1084a9a9b91d4`；重新解包后
保留可执行权限，26 项真实 worker/协议测试全部通过。证据见
`phase3/ast-deliverable.json`。此包针对 Linux x86_64，携带所需 Cangjie/process 库，
仍依赖记录的 Linux 系统库；不要求用户设置 SDK checkout 或 LD_LIBRARY_PATH。
CI 使用的 `scripts/prepare_ast_plugin.py` 自动准备入口也已实际执行固定下载、构建、
打包和全部 26 项检查；不是仅把 helper 写入门禁但未运行。
Foundation 的性能样本先于独立 AST 包与文件计划路径，不能代表当前 1.1.0 大包的
安装、重复内容摘要扫描、查询或编辑开销。当前尚无与起始版本同口径的完整 AST
性能对照，不据旧采样声称此次外迁满足性能预算或已有优化。

### 独立网页搜索与受控 HTTP 检查点

`plugins/web_search` 是独立构建的原生进程包，不依赖 Product 或旧静态扩展。Brave、
Tavily、SearxNG 的参数解析、auto/provider 选择、URL/query/body/header、结果解析、
内容展示和错误形状都由插件持有；宿主的 `plugin_http_configuration.cj`、
`plugin_http_preparation.cj`、`plugin_http_service.cj` 只处理通用 HTTP 意图、精确配置、
凭据引用和执行。协议与配置见 [通用 HTTP 服务](plugin-http-services.md)。

插件的纯 prepare 阶段不获得网络、秘密或 UI，只提出请求。宿主冻结 input、非秘密
configuration、包摘要、实例 generation、配置 digest 和请求；审批后的子调用只能
引用已准备的 intent ID。GET 与 POST 均受既有 canonical 来源、父预算、单槽派生、
Operation/Receipt 和取消约束，不能把 HTTP 请求包装成只读 Workspace 子调用。
秘密在执行时由 operator 指定的位置注入，不进入插件输入或持久化计划。完整 HTTP
4xx/5xx 是已完成的交换，由插件转成业务错误；断流、超时、截断或秘密回显保留
Unknown，插件返回成功也不能覆盖真实 child Receipt。

兼容边界是显式的：旧隐式环境 provider/key 发现不再是新插件的授权来源；即使
provider=none 或 auto 无可用 provider，也需要绑定当前包 digest 的空 operator
配置条目。离线 help 命令不需要 HTTP 配置。新端点的响应 body 和最终编码结果
各限 64 KiB，诊断有界且 UTF-8 安全；纯 parser 的旧 16 MiB 上限不代表 IPC 承诺。
业务 result 字段保留，error 非空时协议 ok=false，通用 CLI 才能返回失败退出码。
现 native worker 固定资源 profile；比它更严的父进程限额明确拒绝，不冒称已在
更小的 4096 字节/32 FD 限额下运行 curl。完整发行和跨平台性能仍未验收。

本轮最终 HTTP 定向源码清单摘要为
`e05d66ddcb50a74610e04fda63e546b6aced157354dae982ce4e4ea81c558756`，
测试二进制 SHA-256 为
`cdfd2e7ee43ba26d5459285bfc6a08a47fce42b8b77b5c1139ad7a5c66075851`。
`phase4/http-product-5/summary.json` 记录从 122 项枚举中选择的 **20/20 实际通过**，
每例独立进程、精确 filter、90 秒上限；单例输出 TOTAL 122 / PASS 1 / SKIP 121。
该 round5 结果只证明上述 20 项定向范围；随后删除旧内建路径的全量结果另见下表。

| 实际执行范围 | 证据与结果 |
| --- | --- |
| 独立 Web 纯业务 | 29 项单元全通过，dry-run 精确 29 项；真实 compiled unittest 摘要和二进制 hash 由 `check-business.py` 校验，不只依赖 cjpm exit 0 |
| 独立 Web 进程协议 | 最终 package4 的 30 项真实进程用例通过，含 opaque string invoke ID、`sha256:` 包摘要、安装实例 generation 与 worker generation 独立、取消/迟到/业务错误/大小边界；证据 `phase4/web-endpoint-4` |
| Product 配置 | 6 项通过：缺失/错误 digest、未知字段/版本/通配 grant、秘密惰性解析、路径/符号链接、注入位置碰撞、撤权和显式 env 引用 |
| Product HTTP 执行 | 7 项通过：实际独立 Searx 包经 gateway 完成含 Unicode/保留字符 query 的请求且卸载 Shell 后可用；无 HTTP 配置的离线 help；Committed 审批与真实 Pi hook effective arguments 恢复；Direct GET/503；未知结果/回显、越权零效果、撤权/取消 |
| Product 传输 | 7 项通过：真实 curl 可读取污染 curlrc 时仍只请求批准 URL，Product 路径 attacker 请求为零；302 不跟随；恰 64 KiB ASCII 完整成功，超长 Content-Length/chunked 和 JSON 转义后超限保留 Unknown；父更严输出/FD 限额明确拒绝；预取消/过期零 HTTP；活跃请求服从父 deadline；相同 callId 不同 Thread 取消隔离，A 第二 intent 已准备但无派生/交接/HTTP，B 经独立 release 正常完成 |
| Store | 完整契约实际通过，含 Direct/Committed 的 72 个 HTTP ParentIntent 场景，以及真实 Committed 审批 canonical/effective input 证明；`phase4/http-authority/agent_store_contract-attempt-4/summary.json` |
| Tool Runtime | 完整契约实际通过，含 GET/POST prepare、密封 Committed 审批恢复和 derived admission；该层不执行真实 HTTP；`phase4/http-authority/tool_runtime_contract-attempt-4/summary.json` |
| Core | 完整契约实际通过，新增 approved nested slot 的 completed/rejected/budget/cancelled/throwing 五场景：父调用不重复计费，批准后拥有并暂让单槽，取消/异常均释放，handoff 后异常保留 Unknown；`phase4/http-authority/agent_core_contract-attempt-1/summary.json` |
| 正式 CI 包准备入口 | `product_unit_gate.prepare_bundled_plugin` 串行构建新的 AST 包并运行 26 项检查，再构建新的 Web 包并运行 29 单元/29 枚举/30 协议检查，全部通过；`phase4/plugin-gate-preparation-1/summary.json`；不是复用环境变量指向的旧包代替构建 |
| 删除后的正式无模型 CLI | `support_tests/plugin_cli_blackbox/check.py` 以真实 App 和独立包完成 17 项检查、67 次调用；本地 import/enable、七参数 inspect、独立 help、审批拒绝零 HTTP、Direct/ParentIntent/Receipt、业务 HTTP 错误非零退出、隐藏服务不可直调、真实版本更新/回滚/卸载/GC/doctor；`phase4/cli-formal-1/summary.json` |
| 正式 CLI 全新包门禁 | `support_tests/plugin_cli_blackbox/run.sh` 重新构建基础包并通过 29 业务/30 协议检查，再从独立源码副本编译真实 1.0.1 并通过 30 协议检查，随后 17 检查/67 调用全部通过；5 项真实进程清理测试同时通过；`phase4/cli-gate-1/summary.json` |
| 独立 Web 1.0.0 发行归档 | 以正式门禁的新基础包制作可安装 tar，在原生 Linux 新目录解包后 30 项协议检查通过；12 个文件及 7 个随包运行库与原包字节、provenance 相同，逐个核对 RPATH；`phase4/web-deliverable-1/summary.json` |
| 删除后的相关合同 | `extensions_contract`、`extension_runtime_contract`、`testkit_extension_contract`、完整 `product_thread_runtime_contract`、`product_rpc_contract`、`thread_runtime_integration_contract` 均重新构建并直接运行二进制，成功 marker 与 exit 0 均核验；`phase4/related-attempt-1/summary.json` |
| 删除后的完整 Product 合同 | 同一已构建二进制在原生 Linux 工作目录执行通过；首次 DrvFS 工作目录的模式断言失败记录保留，见下文；`phase4/product-contract-native-1/summary.json` |
| 删除后的全量 Product 单元 | 正式 `product_unit_gate.py --package agent_product` 精确枚举并逐例隔离执行全部 122 项，**122/122 通过，0 failed/error/skipped**；`phase4/product-full-2/summary.json`；20 项 HTTP 定向属于此覆盖，不另外相加 |

Core 证据的源码摘要为
`bc3d5b98a8d957fb165e8cefc073c18486eed7396bc6ba675c8c57ebc0bd31d1`，
二进制 SHA-256 为
`ecbbaa52832ebc8597cf6680d00bd7b405e448d283ea010cd1c6bcf01f94d7a8`。
构建前后源码摘要一致，日志同时包含 `Core approval nested slot contract passed`
与完整 `agent_core contract passed`。这些执行继续使用前述 WSL/SDK/stdx 工具链
及已有依赖缓存；不能宣称 clean-env 验收。

早期候选的真实失败保留在各轮证据中：wire fixture 最初错误使用数值 invoke ID，
随后发现真实包摘要带 `sha256:` 前缀、安装实例与 worker generation 不是同一计数。
这些不匹配已修并重新打包测试。真实 Committed 审批还暴露有效参数恢复和批准后
父执行槽缺失，修复复用原 canonical 证明/预算；Pi 测试自身遗漏 PreToolUse grant
也已补齐，未放宽生产 hook 授权。最终 round5 的通过不追溯性改变旧候选的失败。
删除前 CLI 历史检查点的 App SHA-256 为
`50ba3569843e543fe517973b3844a40dc93367d641429880c0a1c4c4a5a1acbe`，
总 wall time 为 771.91 s；这不是单次请求性能指标。升级的 1.0.1 包由独立源码副本
重新编译，并通过 30 项协议检查；仅改 manifest 的伪升级被拒绝，没有用它代替
真实版本协商。原仓库包仍为 1.0.0。

删除旧路径后的 App 构建前后递归生产源码清单摘要均为
`3b46902b8ff7e7b4fc26727f0c15f7eed0eabb81617a12cd7626b3c3e3cfea89`，
二进制 SHA-256 为
`b2b587742050b324c93e38539ff3fb177326d737dfdaf16afc44cf8cb15418f9`。
正式预构建包黑盒耗时 795.90 s；全新包门禁中的黑盒耗时 781.11 s。
两轮都验证 App 摘要前后不变。它们是多次独立 CLI 启动的正确性验收，不能作为
单次请求或性能改善指标。测试无模型凭据、不使用 `--fixture`、不伪造注册，也不
修改安装锁；只读 SQLite 检查真实 canonical 来源、handoff、派生准入和 Receipt。
新摘要不能继承旧 HTTP grant；回滚恢复旧身份但保持 disabled，显式 enable 后
才可使用仍匹配原摘要的 operator 配置。卸载后 GC 保留仍被历史引用的 3 个快照，
并非清空历史。两次精确临时目录的只读进程核对均未发现相关运行进程。

交付的 `axyndra-web-search-plugin-1.0.0-linux-x86_64.tar.gz` 为 12,488,136 字节，
SHA-256 为 `803f83cdfe65cd96f95e2e5867263618a84ac8baa99e9215ef4af3382f8d3016`。
它来自真实 1.0.0 基础包，不包含 1.0.1 升级测试副本。DrvFS 对源目录统一报告
0777，首次归档因此未通过发布权限断言，失败记录与归档已保留。最终在原生 Linux
暂存目录仅规范权限：目录、入口、运行库为 0755，JSON 与许可文本为 0644；
文件字节不变，tar 解包后与暂存目录的模式及字节均相同。端点在移除 SDK 和
`LD_LIBRARY_PATH` 环境后通过 30 项检查；声明的 Linux 系统库仍是运行条件。

首次相关合同汇总 `phase4/related-attempt-1/summary.json` 保留 **FAIL**：
其中 `product_contract` 在 DrvFS 工作目录触发
`multi edit retains exact executable and private modes` 断言；其余六个合同通过。
随后保留生产代码、断言和同一二进制
`4de03f8d2b67e2b357e7bb2181bcf038126b0ea914844acb5eb22210055dc01a`，
在原生 Linux 临时工作目录重新运行完整 Product 合同，得到 exit 0 和
`product contract passed`。该重跑继续使用 phase 3 的真实 task-local Pyright、
Bun、Ruby 依赖；未重编二进制或替换为模拟语言服务器。最终结论须结合这份
`phase4/product-contract-native-1/summary.json`，不能覆盖首次失败日志，也不能
宣称 DrvFS 支持已经通过该模式断言。

最终 Product 全量单元执行的源码清单摘要为
`89c4b3403960c3eb2824f343f1a200d54b0e8a7e2dc9aa8e77b7b22423964578`，
构建、枚举和全部 122 例隔离运行期间保持不变。正式门禁的 summary 为 PASS，
外层 exit code 为 0；初次候选与早期定向结果仍保留，不能反向替代这份最终证据。

旧 `web_search_tool.cj`、静态扩展 package、Product/Application 专属方法、search CLI
和旧 fake transport 合同现已删除，SDK 示例改用不含 Web 业务的测试扩展。
当前结构测量为 37 workspace packages、42 本地图节点、126 条审核基线违规；
15 项变异测试通过，严格 Minimal 仍拒绝 84 条其他能力耦合。本节只证明注明的
检查点；Minimal/Coding/Full 发行和完整性能回归仍按实际结果补录，
不据此将 A1/A7 或整个 issue 标为完成。

## 2026-10-04：服务与动态目录基础检查点

本批继续以 `90d21461ee13c874a7c9f2f8e39e0073f048357e` 为增量基线。
已落地同一 ToolCatalog 的宿主 owner、原子批次发布、不可复用实例身份和 Thread
作用域投影；Core 在模型请求前与恢复时检查快照所属 Thread，fork 不复制可变服务
实例。原生 Service 与 Tool/Command 共用已有进程宿主，增加严格服务声明、实际
调用身份及无 broker 权限的纯准备阶段。HostService 通过真实 SystemNote、既有
Inbox/Step/Run 和 canonical ToolCall 准入，保留原始来源，不伪造用户或模型决策。

实际基础验证汇总为 `phase5/service-foundations-validation-summary.json`：
Store、Tool Runtime、Core、SDK 的完整合同通过，Extension Runtime 21/21 单元、
Service 定向及完整合同通过；Product 本批选中 35/157 例通过（服务入口 3、
生命周期配置 7、原始通道 25），不能将它表述为全量 157 例通过。Service 拒绝
反例分别实测入口类型、Node runtime 和非原生服务声明的精确错误；早期错误夹具
及失败记录保留，没有放宽生产约束。真实 C 命令、工具和服务三种 fixture 均重新
构建并验证协议，运行前后的 fixture 字节和对应源码清单均固定。

原始 ProcessChannel 有界读写、累计字节及进程资源限制、独立取消和逐 Operation
清理已验证。终止信号被接受与实际清理完成分别记录；延迟取得 gateway、清理失败
和清理重试期间继续保留 owner/容量，不能凭取消返回成功释放资源。MCP 的注入
stdio transport 同样保留未完成清理，关闭调用有界且拒绝虚假 ACK；该修复在
`phase5/mcp-cleanup-attempt-1/summary.json` 中通过完整 63/63 单元及独立构建后的
完整 MCP 合同。localhost HTTP fixture 的代理环境隔离仅属于测试，不改变生产
HTTP 网络策略。

后续固定 Service 端点、真实 lifecycle lease/启动控制已通过实际验证，记录于
`phase5/service-lifecycle-pinned-validation-summary.json`：Product 定向 24 项、
Runtime 全量 26/26 和 Service 短/完整合同通过。Runtime 早期失败由测试在持有
模拟 close 门闩期间读取同一终止锁造成；改为记录真实 terminate 返回的原子观测，
保留卡住的尝试、精确进程组终止及诊断，没有改写清理完成的生产判定。

`phase5/channel-prepared-manager-validation-summary.json` 继续记录四个独立源码
依赖图。Store 全合同及新增 82 个通道 ParentIntent 场景、Tool Runtime 全合同、
MCP 73/73 单元及独立完整合同通过；Product 管理器 6、owner 7、启动控制 4、
固定端点 6 共 23 项通过（枚举 180 项，不能表述为全量通过）。原生三种 fixture
按新源码重新构建并验证。通道子调用仅接受自身的 request-key 前缀，HTTP 等既有
端口保留原前缀，双向交叉前缀拒绝有真实准入反例。MCP 请求的纯冻结接口不产生
I/O，发送时复用不可变的 JSON/stdio 字节和 client seal，失败不退还已发送标识。

随后 `phase5/mcp-immutable-attempt-1/summary.json` 记录 MCP 76/76 单元与完整合同通过。
新增 HTTP 准备步骤在零 I/O 下固定 URL、方法、协议和参数 headers、正文及超时；
真实 HTTP/SSE 测试在修改输入、当前 schema 和配置后仍发送原请求。该库 DTO 不是宿主
授权对象，兼容工厂的明文认证字段不能被插件作为 IPC 计划使用。

独立 stdio Client 包由正式 `scripts/prepare_mcp_plugin.py` 构建，
`phase5/mcp-plugin-twenty-attempt-1/summary.json` 记录 20/20 协议用例通过；其中包含
连续 24 次合法大响应、12 个新进程的超限响应、分页 TTL/cacheScope 一致性及错误身份
拒绝。原先间歇卡死的真实栈显示 ConsoleReader 阻塞导致 GC 等待，改为复用有界 fd
轮询读取后通过这些回归，未扩大超时。包入口 SHA-256 为
`0531c4ed962a7735e9226b506dd418956e44f5ffa20efc889d796a3a3483f7fa`，测试清除 SDK
库路径变量，并核验包内运行库、StdX LICENSE/Notice 和全部产物摘要。

受管通道的主动 I/O、独立 MCP Client 安装调用已通过实际 Product/SQLite 回归。
`phase5/mcp-stream-foundation-validation-summary.json` 汇总本阶段证据：同一源码图
`657237953a3d5fd306e031867af9db345d05613b452ca4436542dd14468e7da8`、Product 测试二进制
`db9095acdedf039c7ef12b98a390e9c5cef5553246a0c5e6a72c82677b921476` 的 36 项相关测试、
5 项 MCP 集成测试和完整 200 项 Product 测试全部通过。完整套件先从实际二进制枚举，
再为每项启动独立进程；与同二进制的 cjpm 单项结果核对一致。这是直接运行测试二进制的
完整回归，不称为 cjpm CLI 完整门禁。前后源码、二进制和 fixture 摘要未变化。

回归修复了三类实际问题：端点内部取消不能冒充调用者取消；执行器已观测的 Unknown
不能被事后目录撤权改写；真实派生写入失败后，插件的普通业务错误终态不能掩盖未知结果。
累计输入额度包含启动和后续写入，撤权后阻止新的交接，清理完成前保留资源所有权。
实际 Tool 合同新增五种事后撤权结果场景并通过完整套件。Runtime 的 29 单元、完整
Extension/Service 合同以及独立 MCP 的 76 单元、完整合同和 20 包协议测试也已通过。
这些不同构建图的结果分别记录来源，不能合并声称属于同一个二进制。

包摘要计算改用有界流式 SHA-256，保持原有 tree-v2 身份格式并继续完整重读，不缓存授权。
同一 50 文件、55203323 字节包，预热一次后各五次纯检查样本的中位数由 9.224030 秒
降至 2.021295 秒；独立 Python 校验的包摘要相同。此测量不证明原子文件快照或消除 TOCTOU。

应用端通用启停命令、外部请求来源、目录刷新及 HTTP 流式组件正在后续集成；
独立包的协议 broker fixture 不能冒充 Product/SQLite 授权证据。尚未交付完整外置 MCP Client/Server，也不证明
Minimal 已移除 MCP 依赖、动态服务完整恢复或整个 Epic 完成。

## 2026-10-04：应用入口、External 来源与显式刷新检查点

本批以 `72ac133b0c37c1447bc454be0922e349c8c29e30` 为增量基线。
持久 ApplicationSession 现在通过通用服务命令显式审批启动、列出、刷新和停止当前
Thread 的服务；视图切换不转移旧 Thread 的启动或取消权。退出与关闭保留实际清理
所有权，不能把请求终止当作清理 ACK。刷新使用独立 HostService maintenance Run、
有限读写窗口和同一个目录 CAS；事后失败保留 Unknown，旧 Prepared 不能跳转到新
executor。活动 Core Run 的 #39 安全切点接入仍属于后续未验证候选。

External 来源新增有类型的 principal/连接/请求 seal，进入真实 Runtime/Store
准入、审批、handoff、Receipt 和恢复校验；调用者提供的 JSON 不能伪造该来源。
这个来源机制不是 MCP Server 已外置的证明。HTTP 新增严格响应头、分块解码、
跨块秘密过滤、流 reader 和实际通道终态缓存；本批 helper 结果不证明完整 HTTP
流式 factory 或 MCP HTTP 产品路径，二者仍在单独候选中。

`phase5/app-external-refresh-validation-summary.json` 封存本批实际证据：
Tool Runtime 全合同、Store 全合同（含 External typed codec/seal、7 个撤权 fence、
8 个持久化 fence、既有 82 个 Channel 场景）通过。正式 helper 全新构建的 stdio MCP
包通过 25/25 协议用例，入口 SHA-256 为
`e55033714a244a01db000eceeaa92012f8929238b50c431f68dd4e0cc6718010`。

同一 Product 源码图
`b0e5bc81c6f65e086c7b09ed6004730765da807c2ea8ec7fcf7d8c7e553bb343`、测试二进制
`21078f5ecfe5b03c20d61109745587139aa98e554866c0446b95681ef3212462`，实际枚举 237 项，
先通过新增 37 项和既有 5 项 MCP 定向，再完整执行 **237/237 PASS**。每项使用新
进程；同二进制 cjpm 单项结果与直接执行核对一致。它是完整测试二进制回归，
不称为 cjpm CLI 全量门禁。源码、实际 fixture 和二进制运行前后摘要保持一致；
已使用固定 SDK 和依赖缓存，不声称完全空缓存构建。

首轮全量在旧 OS 隔离测试的本地 server readiness 阶段停止：155 PASS、1 FAIL、
81 未运行，原始日志保留。原 fixture 按时钟选择未预留端口，并在退出时丢失诊断；
现改为 OS 分配端口、实际 ready 文件和有界错误诊断，仍保留原 5 秒期限以及全部
文件/网络隔离断言。修复后的该用例独立运行和整套顺序均通过。原失败的具体原因
无法从被清除的原现场确认，不能据此断言已经证明端口冲突。

本批不删除旧 MCP 产品实现，不把 stdio 协议 fixture 当作 SQLite 或 Minimal
证据。HTTP/Server、认证兼容、#39、旧路径删除和无 MCP 源码的干净宿主构建继续
分别验收；完整 A0–A7 范围保持不变。

## 2026-10-04：HTTP、独立 Server 与活动模型目录切点检查点

本批以 `cbe99f3a38ac20f332bd9005104823f2a7bf76af` 为增量基线。MCP Client 的
HTTP/SSE 传输现在通过通用受控流服务执行，启动和刷新使用真实批准的 maintenance
窗口；活动调用只能使用准备时冻结的 ParentIntent。读、关闭和清理 ACK 仍归同一
Operation/Receipt 权威，失败不自动重放。Store 完整合同包含 82 个新增 HTTP 流场景。

`plugins/mcp_server` 是独立安装的协议 decoder；通用 `plugin serve` 入口只管理
有界 stdio、固定导出目录和外部来源。真实 App 的 9 项测试覆盖 External v3 的
SystemNote、ToolCall、handoff、Receipt 与原始帧摘要，审批前零效果，有类型请求 ID，
在途和排队取消、后续调用、输出背压以及断流清理。空导出目录可用。独立 decoder
12 项与 Client stdio/HTTP 36 项协议测试分别通过；协议 fixture 不替代上述产品证据。
旧内建 Server 尚在，输出容量、认证和完整兼容范围仍须比较后删除。

活动 Core Run 在恢复完成、工具轮次结清且没有活动 Attempt/批次/执行槽时，按
#39 的同一 Store 事务提交目录变化并进入下一 Attempt，保留预算、token、序号和
既有恢复义务。已结清的模型 continuation 保留 sealed checkpoint，恢复后不会重复
执行已提交决定。相关 Store/Core 合同和 2 项 Core 单元通过。单槽嵌套任务先登记
真实子 Future 再越过执行 barrier；未取得清理 ACK 时仍持有任务、执行槽和 Unknown。

汇总证据 `phase5/http-server-validation-summary.json` 的 SHA-256 为
`2e27f4b24092a44b710f1f1e2944033b2ddc23c6331bd938879e3f5e1900f6ee`。
其中列出的 17 份记录包括 native borrowed-fd 5 项、全部相关 Store/Tool/Core/
ThreadRuntime/SQLite/Extension Runtime 合同、Extension Runtime 29 项单元、上述
独立包和 App 验证。Product 源码清单摘要为
`ff87feca96ad73c7a8f7b42c34accf8b064697223074a41b738c32dcd843dbf3`，实际二进制为
`465f18f01d004b5634474f139a79dde07e33c0a5827816f292a501c932bdc139`。实际枚举并完整
执行 **256/256 PASS**，新增 19 项和旧 MCP 5 项定向均属该覆盖。每例使用独立进程；
cjpm 枚举与单例 CLI/直接二进制结果核对一致，不称为正式全量 cjpm CLI 门禁。
源码、fixture、二进制运行前后摘要一致；SDK、StdX 和依赖缓存有复用。

先前失败日志保留：编译可见性/构造器类型修复、旧 Store fixture 的 composition
标识修正、Core 原先“恢复行数为零”断言改为验证合法 sealed checkpoint 及恢复
不重复执行，以及 Server fixture 补齐实际必需的 clientCapabilities 元数据、精确
检查协议错误。没有以跳过断言、删除失败记录或改变生产审批政策使其通过。

该 256 项检查点尚未覆盖认证前缀、环境和秘密注入、operator 只读工具政策、显式
HostNetwork、容量配置；这些增量的后续实测见下节。旧 MCP 路径删除、无 MCP 源码的
Minimal 构建、固定宿主安装恢复、
更大负载、长超时及其余 A0–A7 内容继续逐项实施；本检查点不代表 Epic 完成。

## 服务兼容与容量实际检查点（291 项）

基于 `d3e9a3a53682b22fd1dd450285eb0767efebe160`，完成显式认证前缀、受控环境与
秘密引用、operator 只读声明、HostNetwork 与有界容量配置的实际验证。正式包准备
入口新建 MCP 包并通过 **44/44** 真实协议检查；Store 完整合同覆盖只读 84、容量 9
等场景，Tool 完整合同、Extension Runtime **29/29** 及完整 Service 合同通过。
实际 Product 枚举并独立进程执行 **291/291 PASS**。关键 36、旧 MCP 5 与相关生命周期 11 项定向属于修正 Pi
监听 fixture 之前的独立图；最终完整 291 项重新覆盖了全部用例。相关 sandbox 和 direct-runtime sandbox 合同在原生 Linux
目录执行通过。不是把旧图成功拼接成新图全量成功。

Product 源清单 SHA-256：`e64b3974310cf50764af32ad79ebe4cb74c754d603178b9ae913dca61d87bc6b`；实际二进制：
`4c9649b1ef9480cea5d12ef8356c88e37c502c1baf8421d79d213f3d7b89e4db`。汇总 `phase5/service-capacity-final-validation-summary.json`
SHA-256：`6df315091c3fb852aec285f067ce6a383cd500c793df01c6a72cecdd145c25d7`，包含逐命令、日志与 fixture 摘要、不同依赖图及未运行项。
全量采用实际 cjpm 枚举、同一二进制单例 CLI/直接执行一致性检查、每例独立直接
执行；不是正式全量 cjpm CLI 门禁。SDK、StdX 1.1.3.1 与 Cangjie 依赖缓存有复用。
最新 App 9 项结果仍属于前述 256 图，本检查点不声称 App 重新构建验证。

真实 96 KiB 输入/输出、72 工具九页发现、11 秒调用/15 秒配置均通过。跨 64 KiB
写入保持一个 canonical child、完整冻结字节与总额一次计账；每片重新验证取消、
来源、Store 与 lease，部分失败保守 Unknown，不能借分片获得新授权或重放。
Host 实际联网与 Denied 拒绝分别验证；固定 CA 未配置时，私有 launcher 不能继承
宿主 CA 环境变量。该空 CA 用例验证工厂边界，不冒称代替 canonical Store 准入。

`read_only_tools` 不等于预先批准网络。默认 `ask_on_network: true` 的 HTTP 根调用
实际要求审批且无 `tools/call` 或派生执行；正例与远程 annotation 拒绝例明确使用
operator `ask_on_network: false` 排除网络提示遮掩。根可为 ReadOnly/NeverReplay，
实际 POST 子调用仍为 ExternalMutation/NeverReplay。撤销后只在真实有限清理 ACK
后归还容量；拒绝状态仍立即证明零 handoff 和零 peer 效果。

早期失败永久保留：被拒审批的 canonical 终态 fixture、refresh 的真实第二次
`tools/list` 触发点、异步清理 ACK、独立网络审批政策、Host 固定 CA 注入/允许名单
不一致及跨片写入真实宿主边界。此前 290 全量在 84 PASS 后因旧 fixture 把 canonical
`["host"]` 误写为 `host` 失败；修复同义断言并加入空 CA 收窄后重新完整执行 291 项。
随后首轮 291 在 175 PASS 后遇旧 Pi 本地服务器未就绪；固定旧二进制单次元数据
诊断通过，原启动失败根因未确定。将该 fixture 的墙钟端口改为系统分配实际端口，
保留 5 秒期限、无重试及全部隔离断言，添加错误和存活诊断后，再次完整执行 291 项。
旧失败未覆盖，旧定向通过不作为最终图全量证明。

这仍不是旧 MCP 路径删除、无 MCP Minimal 宿主、完整 legacy 大负载/长超时或整个
Epic 验收。Payload、Observation、GitHub、Workspace、Eval 等后续候选未进入该图。

## 历史检查点逐项跟踪

完整范围保持 issue 的 30 个 A0–A7 项目；未经明确批准的延期不视为完成。
`Done` 仅表示该行限定的交付与验收完成，不表示整个 Epic 完成；`Partial` 表示已有具体增量但未达到该行
全部验收；`Open` 表示仍需迁移。代码更改和定向测试通过不能代替整项验收。
该历史检查点为 **3 Done、21 Partial、6 Open**；此计数不是当前完整组合的验收结果，#45 保持未完成。

| 项目 | 状态 | 当前交付边界 / 尚需证据 |
| --- | --- | --- |
| A0-01 增量盘点 | Done | 本页记录起始 SHA、已有 #43 边界和依赖/分发/配置/命令/数据迁移地图；区分可复用和仍须迁移内容 |
| A0-02 统一 ADR | Done | ADR 0004 明确统一贡献/实例、信任、授权、版本、自举、breaking 及 #34/#35/#36/#39/#44 关系；设计落地按后续各项验收 |
| A0-03 行为与依赖基线 | Partial | 新增结构基线、棘轮和严格 Minimal 入口，复用既有性能采集器；完整默认行为对照、干净构建/安装及产物证明尚缺 |
| A1-01 包/实例/贡献与 SDK | Partial | 支持原生可执行入口、声明 Tool/Command、无 Tool 命令插件、实例绑定及静态版本拒绝；组件依赖、完整协商/贡献种类和旧原生 SDK 退出尚缺 |
| A1-02 进程与受控服务 | Partial | 原生端点、受控 stdio/HTTP 流、冻结请求、lifecycle 窗口、取消/清理 ACK、显式环境/秘密/HostNetwork 和有界容量已有真实验证；完整故障与更大负载矩阵仍缺 |
| A1-03 执行与来源闭环 | Partial | Direct/Committed/Derived 来源、AST 和 HTTP 同预算派生已有真实证据；HTTP 请求在执行前持久化父意图，已批准恢复绑定有效参数并持有执行槽；Prepared 失败持久化与 Unknown 保持均已回归；等待/任务的完整闭环仍缺 |
| A1-04 管理与自举 | Partial | 固定 Git/npm 获取直接使用受控 ProcessPort，无 BashTool/会话 shell 依赖；删除旧 Web 路径后的正式无模型 CLI 和全新包门禁覆盖真实更新/禁用/回滚/卸载/GC；通用组件依赖与完整自举发行矩阵仍须验收 |
| A2-01 MCP Client 外置 | Partial | 独立 stdio/HTTP Client 包通过 44 项真实进程协议测试；实际 Product/SQLite 认证、环境、只读、HostNetwork 和有界容量验证，同图 291 项 Product 全量通过；Application 仍引用此前已测 256 图。更大负载兼容、旧路径删除及无 MCP 宿主构建仍须验收 |
| A2-02 MCP Server 外置 | Partial | 独立 decoder 12 项及实际 App 外部来源/审批/取消/背压/断流 9 项通过；有界 stdio 入口与固定导出使用通用宿主，旧内建 Server 删除及容量/认证/完整兼容仍须验收 |
| A2-03 MCP 生命周期与交互 | Partial | stdio/HTTP Client 发现与刷新授权、原子目录、旧 Prepared 拒绝、Thread 生命周期和 Server 外部取消已有真实证据；活动 Core 目录切点接入已验证；挂起/远程任务的能力诊断及完整支持矩阵仍须逐项验收 |
| A2-04 删除 MCP 内建路径 | Partial | 已删除通用 agent_extensions 的 MCP 强制依赖；产品运行时字段、具体分支及传递依赖仍存，严格 Minimal 预期失败，固定宿主安装恢复尚缺 |
| A3-01 AST / 网页搜索 | Done | AST 查询/编辑和三家网页搜索 provider 业务已在独立包，旧宿主实现/静态 package/专属 search CLI 已删除；AST 26 项包测试、Web 29 业务/30 协议、删除后的七个相关合同、122/122 Product 单元及正式全新包 CLI 17 检查/67 调用通过（Product 合同使用原生 Linux cwd）；可安装 Web 1.0.0 归档解包后 30 协议检查通过，真实安装/禁用/升级/回滚/授权边界均有证据。全局发行与性能矩阵仍归 A0/A7 |
| A3-02 GitHub | Partial | 独立 gh/git 插件的 10 项真实协议及 5 项 Product/SQLite 合同通过，冻结命令、审批、撤权、进程树取消、秘密反射拒绝有证据；完整容量/时限等价及旧产品业务路径删除仍缺 |
| A3-03 LSP / DAP | Open | 独立插件候选已实现，Product 内建 DAP 及静态依赖已删除；仍待当前组合的真实安装、完整调试合同、授权、恢复和清理验收 |
| A3-04 eval | Partial | 独立多语言包 20 项进程协议及 5 项 Product 服务合同通过；真实连续单元、reset、审批、取消、Unknown 和实例隔离已有证据；旧 timeout/session/artifact 行为等价、缺解释器完整矩阵及旧装配删除仍缺 |
| A4-01 Workspace 插件 | Partial | 独立包 31 项协议与 3 项 Product 合同通过；read/search/glob、跨重启 hashline 计划、精确审批、冲突及多文件原子 CAS 已验证；大目录/大文件完整等价和旧静态工具/业务分发删除仍缺 |
| A4-02 Shell 插件 | Open | Bash/PTY/异步工具尚未外迁；本次仅移除维护执行器对 BashTool 的依赖，不能据此宣称 Shell 插件完成 |
| A4-03 Program / 计划能力 | Open | worker/语言适配/工具包装仍由产品装配；现有只读派生和精确计划权威保留，外迁尚缺 |
| A4-04 Coding 发行版 | Open | 默认工具仍静态装配；锁定清单、独立升级/禁用及编码/审批/取消/恢复发行验证尚缺 |
| A5-01 Context/Resource 与 Skills | Partial | ToolInvocationContext 改为不可变通用投影，删除 tool_runtime 对 agent_skills 的直接依赖，并验证有界/惰性/信任/固定引用；Core/runtime/store/embed 具体 Skill 类型和间接依赖仍存 |
| A5-02 Memory / Compaction | Open | 检索/embedding/摘要算法未插件化；宿主数据访问/删除、合法切点/预算/checkpoint 权威不变，不能新建会话事实 |
| A5-03 Planning / Todo / Goal / Subagent | Open | 策略、工具、角色及路由仍在产品；外迁后需复验既有子运行/权限/审批/预算/父子取消 |
| A5-04 动态更新与恢复 | Partial | 服务目录接入同一分支/lane/Attempt 安全切点和 Store CAS，保留预算/序号/恢复义务，已提交决定重启不重放；完整并发/fork/缺失插件/撤权/内容变化矩阵尚缺 |
| A6-01 Provider 契约 | Partial | 类型化 ModelProvider 贡献、安装选择、真实 Attempt gate、受控 HTTP/凭据、终态/usage 与清理所有权已有实现；401 枚举图中的 35 项 Model 实际定向通过。旧选择/配置依赖退出、完整能力与容量兼容仍缺 |
| A6-02 实际 adapter 迁移 | Partial | 独立包承载 Chat Completions、Responses、Anthropic 三种真实 wire adapter；三种已安装 contribution 均经实际 HTTP/SQLite Attempt 验证，包 33 项协议检查有独立图证据。宿主仍可达旧静态 adapter，配置迁移、完整等价及删除尚未完成 |
| A6-03 无模型与异常 | Partial | 实际安装路径已验证缺失/撤权/错误映射、凭据反射、流中取消、部分输出/协议失败、unknown usage、清理债务和真实 ACK；通用无模型管理已有先前 CLI 证据。无模型 Minimal 发行与完整崩溃/替换实例历史恢复仍缺 |
| A7-01 生态适配 | Partial | Pi 与原生复用同一现有进程宿主，兼容范围/不支持项已有文档和定向回归；Codex 和其他贡献、完整新契约迁移仍缺 |
| A7-02 配置/存储切换 | Partial | 插件 plan/v2 新格式绑定真实来源；Program v1 保留读取，apply/recover 都须有持久化生成/恢复证明，无证明明确拒绝且保留 artifact bytes；完整插件配置/全 Store 切换、备份/升级中断/回滚仍缺 |
| A7-03 发行/文档/诊断 | Partial | 新增协议文档、C 原生命令/工具 fixture、CLI 结构化贡献诊断和门禁入口；Minimal/Coding/Full 清单、独立产物、RPC/TUI 全矩阵及 clean-env 打包尚缺 |
| A7-04 全矩阵及旧路径删除 | Partial | 增加实际 native/派生/上下文/取消/维护定向契约和依赖棘轮；旧原生包激活显式拒绝，但编译旧 SDK/业务分发仍在，完整故障/性能/发行矩阵未完成 |

每次更新状态必须附具体提交/PR 或以基线 SHA 标识的可审阅补丁、命令、结果、
未运行项和迁移影响。新增接口或
声明支持某类贡献时，仍须区分 parser 接受、注册成功、真实执行与崩溃恢复四种证据。


## 2026-10-04：GitHub、Workspace、Eval 和 Unknown 恢复检查点

本批基于 `d9cfdcf519dee68644b342138270fcfb8677b8ce`，先合入 68 文件增量，
再保留编译/夹具修正和由真实重启用例暴露的恢复修复。独立 GitHub、Workspace、
Eval 包分别通过 10、31、20 项真实进程协议检查，均零跳过。GitHub 测试使用受控
本地 gh/git fixture，不修改远端账号。新 Product 合同共 15 项：GitHub 5、Eval 5、
Workspace 3、Unknown observation 2；全部通过后，使用同一已枚举、已验证
CJPM/direct 单项执行等价的 Product 二进制逐项运行 **306/306**，零失败/错误/跳过。
这不是声称执行了正式 CJPM 全量包装命令；公开门禁和逐项进程的证据分别保留。

GitHub 和 Eval 的命令/单元由插件准备；宿主保持实际 Direct/Committed 来源、
派生 Operation、父意图、精确审批、受控进程和 canonical Receipt/ToolResult。
取消或断流后已观测的输出作为不可信 Unknown 证据保留，不据此授予重放或后续效果
权限。只读业务分类不会取消默认网络提示：正向 fixture 显式选择
`ask_on_network=false`，同一用例另验默认提示下零后端命令、零派生效果。
Workspace 验证了独立 read/search/glob 和跨重启的不可变多文件 hashline 计划；
实际应用继续使用既有审批和原子冲突检查。

恢复测试发现，合法父 Operation 与派生 Operation 共用 canonical ToolCall 时，
原恢复查询会误判为重复根。现在从所有相关 Run 中选择唯一无派生准入的根，并
双向核实子 Operation 的父、Run、Item 归属；不借用当前授权复活历史执行。
Store 新增 32 个实际 SQLite 场景：Direct/Committed × channel/HTTP 的 4 个重启
正例，以及每组 7 种持久归属损坏，共 28 个拒绝场景。所有检视均验证不改写原有
持久事实。完整 Domain、Store、Tool、Core 合同和新原生 fixture 检查实际通过。

本次验证源码摘要为
`984d999dcedc8cb34f758eb1856f48548aa7cb8d904c6122a42ad2bd5254b6e5`，
Product 二进制摘要为
`263cae92f2c2b331327f72c1460969636cb6eb1bd130113115dbdaa26f223c06`。
本地证据总摘要 `first-batch-validation-summary.json` 的 SHA-256 为
`f1b407e7edea0b327d146db0e3e7d2eca28723ebaf32c832fca547461325c872`，
包含完整用例日志摘要、原失败记录、修复差量和实际运行范围。验证后只读检查的任务
所属遗留进程列表为空。工具链及部分固定 fixture/cache 被复用，不是空依赖缓存构建。

结构门禁通过并报告 47 packages / 126 项旧耦合；19 项 Linux Python 门禁自测与
库存检查通过，严格 Minimal 仍按这些旧耦合拒绝。Workspace 的版本检查只接受固定
ripgrep 版本后的可选十六进制 revision 后缀，包/二进制/license 摘要检查保持不变；
Eval 修正 4 处不存在的 JSON 数字 helper，观察夹具补齐真实能力和预留 Receipt ID。
所有失败尝试保留，未用事后成功覆盖原证据。

以上只更新 A3-02、A3-04、A4-01 为 Partial。后续容量、语言服务、Context/Skills、
ModelProvider 候选尚未纳入这个运行图；完整旧路径删除、Shell/Program/工作流、
发行、性能及 A0–A7 其余验收继续执行，#45 仍未完成。


## 模型插件实际检查点：401 项枚举、35 项定向

独立 ModelProvider 包已通过真实本地 HTTP 与 SQLite 执行三种 wire adapter；实际
Core 保持唯一 Attempt、预算与 Decision 权威，没有制造 ToolCall 或 Operation。
固定源码图编译并枚举 401 项 Product 测试，其中实际逐例运行的 Model 35 项全部
通过；这里不声称完整执行 401 项，也不替代后续 Context/Shell 等增量的验收。

这 35 项包含缺失/错误映射与撤权、凭据反射、包在派发前及流中被改动、真实 Run
取消、unknown usage、未确认清理阻止重试/安全切点、ACK 精确释放、不可变请求
产物以及 Store 字节/阶段/归属变化。300 KB 请求与回复在原 60 秒限额内完成
（测试自身 23.292 秒）；零 hard timeout 用例保留原 10 秒 HTTP 到达等待及外部
取消与关闭确认。没有通过延长期限或跳过大请求获得通过。

性能修复保留每次轮询的实际 Run/Attempt、请求、当前配置及取消检查，把完整包
摘要放在真实启动/HTTP/终态边界，并在 SQLite 内按 BLOB 精确比较不变快照与
continuation 字节。变化仍触发原解码/摘要/阶段验证，NUL 及所有者变化均有实际
回归。先前失败、诊断堆栈与各独立修复补丁保留，不以诊断退出码冒充测试通过。

源码清单 SHA-256：`3fea97f82980e9ea458aa093f63ac0de6d2064ac57baab527d66b51f42a9c1af`；
实际 Product 二进制：`816389eefb773cb6e21a6efb366c01abfe3231024ead8dce1ff957d8c238765a`。
汇总证据 `model-observation-final-checkpoint-attempt-1/summary.json` 的 SHA-256 为
`c032aa76baad00ea99bdc4cd6322aeae7ad49c4e1bd9d859c9e1f82cd7c5ca1a`。
汇总中的包 33/33 与 runtime 15/15 属于各自先前且依赖未变的图，不能拼接称为
后续源码全量通过。35 项运行前后源码、二进制、包均不变，每例任务所属残留进程
为零；SDK、StdX 和依赖缓存复用，不属于空环境构建。

本次仅把三项已有实际交付的 A6 状态从 Open 校正为 Partial。静态 provider 和
其他旧业务删除、配置迁移、完整行为/容量/故障矩阵、Minimal/Coding/Full 发行及
全部 A0–A7 要求继续执行，不能据此关闭 #45。
