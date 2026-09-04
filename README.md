# Axyndra

一个可嵌入、可验证的独立仓颉 Agent 产品。产品行为由本仓库的
类型化协议、可执行契约和门禁定义，不再以某个外部项目或固定 commit 作为
兼容目标。

`agent_core` 是唯一 Agent 循环，模型、工具、持久化、运行控制和客户端都通过
明确边界组合。仓库只维护产品实现、公共扩展接口、运行时文档和验证资产。

## 快速开始

准备仓颉环境后：

```sh
scripts/pinned_cangjie cjpm build -m agent_app -o agent_app
candidate=$(scripts/package_candidate.sh)
"$candidate"
"$candidate" --print "hello"
"$candidate" --mode json "hello"
"$candidate" --mode rpc
```

默认绝不使用 fixture。首次运行可执行交互式配置：

```sh
"$candidate" setup
```

向导会直接列出 Provider 和常用模型。OpenAI 与 Anthropic 的协议和密钥环境变量
会自动选择，Endpoint 可在官方地址与自定义代理/网关之间选择；只有
OpenAI-compatible 自定义端点才需要选择底层协议。每个 Endpoint 会保存成独立
Provider Profile，API Key 可以隐藏输入并以 `0600` 权限保存，也可以从环境变量
读取或稍后配置。
完成后按向导给出的 `export ...='your-api-key'` 设置密钥。

向导会创建 `~/.axyndra/config.yml`；也可手工编辑：

```yaml
default_model: openai-official/gpt-5
async:
  enabled: true
compaction:
  enabled: true
  max_input_tokens: 100000
  request_max_messages: 24       # 单次请求的异常消息数兜底，不是持久化压缩阈值
  trigger_percent: 88            # 高水位：达到后触发自动压缩
  target_percent: 60             # 低水位：一次压缩释放到这里，形成滞回
  emergency_max_messages: 512    # 只处理异常的超长消息序列
  keep_recent_tokens: 50000
  keep_recent_messages: 12       # 手动 /compact 的消息数兜底
  oversized_tool_result_tokens: 12000
  summary_strategy: structured   # structured（默认）或显式启用 hybrid
  summary_model: ""              # hybrid 留空时复用当前会话模型
  summary_timeout_ms: 5000
  summary_max_output_tokens: 800
  summary_failure_policy: fallback_structured
  models:                        # 可选：按完整模型 ID 覆盖水位线
    openai-official/gpt-5:
      max_input_tokens: 272000
      trigger_percent: 90
      target_percent: 60
```

`config.yml` 负责产品级默认模型、异步任务策略和上下文资源预算，不接受 Provider、协议、Endpoint 或凭据
字段。`AXYNDRA_MODEL` 可临时覆盖默认模型，`AXYNDRA_HOME` 可重定位整个配置与
会话目录。密钥只从 Provider Profile 指定的环境变量或权限为 `0600` 的凭据
文件读取，不写入命令行、会话或持久化请求内容。测试必须显式传 `--fixture`。

自动 compaction 主要由估算 input tokens 相对 `max_input_tokens` 的占用触发；消息数只在
`emergency_max_messages` 作为兜底。`trigger_percent` 是开始压缩的高水位，
`target_percent` 是压缩后的目标低水位。`request_max_messages` 只裁剪本次模型请求，
不会永久删除 session 历史。`models` 下使用 `/model` 显示的完整、区分大小写的模型 ID；
每个模型可以单独覆盖 `max_input_tokens`、`trigger_percent` 和 `target_percent`，未配置字段继承
全局值。模型覆盖同时用于本次 request budget 和该模型会话的自动 compaction；切换或恢复会话模型后，
下一次请求即按对应水位计算。

`summary_strategy: hybrid` 会先生成与 `structured` 完全相同的确定性事实摘要，再用
`summary_model`（留空则为当前会话模型）生成一段标记为 non-authoritative 的语义概览。模型既不参与
压缩切点选择，也不能替换目标、todo、文件、命令、工具结果和诊断等结构化事实；请求关闭工具与流式输出，
并受 `summary_timeout_ms` 和 `summary_max_output_tokens` 限制。超时、模型错误、非法输出或加入概览后超过
目标 token 水位时，压缩无条件回退到结构化摘要。为另一个 Provider 配置 `summary_model` 会把这份确定性
摘要发送给该 Provider，并产生相应费用和延迟。

多个 Provider 或代理可以同时存在。Agent loop 使用 DeepSeek 时，选择 Chat
Completions 或 Responses 方言。Responses 示例：

```yaml
# ~/.axyndra/providers.yml
providers:
  - id: "deepseek-agent"
    provider: "deepseek"
    protocol: "responses"
    dialect: "deepseek_responses"
    base_url: "https://api.deepseek.com"
    api_key_env: "DEEPSEEK_API_KEY"
```

```yaml
# ~/.axyndra/models.yml
models:
  - id: "deepseek-v4-flash"
    provider: "deepseek-agent"
    api: "openai_responses"
    dialect: "deepseek_responses"
    thinking:
      mode: "effort"
      levels: [minimal, low, medium, high, xhigh, max]
```

Messages 兼容端点仍可单独配置。DeepSeek 官方说明该端点支持 tools，但会忽略
`tool_result.is_error`；独立 `llm4cj` 的 DeepSeek Messages dialect 会在失败结果
内容前加上明确的 `[tool_error]` 标记，同时保留 canonical transcript 中的
`isError`。这是兼容性降级，不等同于原生错误字段语义；对必须无损表达工具失败的
agent loop，仍建议使用 `deepseek_chat` 或 `deepseek_responses`。

例如 Anthropic 官方服务和兼容 Anthropic Messages 的 DeepSeek 网关会分别写入：

```yaml
# ~/.axyndra/providers.yml
providers:
  - id: "anthropic-official"
    provider: "anthropic"
    protocol: "messages"
    base_url: "https://api.anthropic.com"
    api_key_env: "ANTHROPIC_API_KEY"
  - id: "deepseek-anthropic"
    provider: "anthropic"
    protocol: "messages"
    base_url: "https://api.deepseek.com/anthropic"
    api_key_env: "DEEPSEEK_API_KEY"
```

模型通过 `profile/model` 唯一定位 Provider：

```yaml
# ~/.axyndra/models.yml
models:
  - id: "claude-sonnet-4-20250514"
    provider: "anthropic-official"
    context_window: 200000
    max_output_tokens: 8192
    reasoning: true
    structured_output: true
    prompt_cache: true
    input_modalities: [text, image]
    output_modalities: [text]
  - id: "deepseek-v4-flash"
    provider: "deepseek-anthropic"
```

`structured_output`、`prompt_cache` 和 `input_modalities` 是真实 capability，配置后会在
网络请求前校验。结构化输出与图像能力不会按模型名字猜测；缓存只有 OpenAI 官方
Responses/Chat Completions、Anthropic 官方 Messages 或显式 `prompt_cache` 声明才会启用。
兼容端点应按其实际协议支持情况明确填写，避免把“能接受同一种 JSON”误当成能力等价。

凭据分别保存在
`credentials/anthropic-official.key` 和
`credentials/deepseek-anthropic.key`。也可以使用
`/login <profile>`、`/logout <profile>` 单独导入或删除某个 Profile 的凭据。

`/model profile/model` 只修改当前会话，并写入会话元数据。`/session` 切回
已有会话时会恢复该会话的模型，`/fork` 继承源会话模型，`/new` 则使用
`config.yml` 中的全局默认模型。旧会话首次打开时会自动补写默认模型。

常用运行参数：

```sh
"$candidate" --model openai-official/gpt-5 --cwd /path/to/workspace
"$candidate" --approval-mode always-ask
"$candidate" --auto-approve
"$candidate" --yolo
```

### 独立 AI 权限审批

默认仍为人工审批。只有显式配置 `approval.mode: ai` 或传入
`--approval-mode ai` 时，原本需要确认的单次工具调用才会交给独立 Reviewer。
Reviewer 使用独立模型请求、没有任何工具，并且只能返回严格 JSON 决策；sandbox、
capability policy、永久禁止规则和持久化 operation 始终拥有最终决定权。

```yaml
# ~/.axyndra/config.yml
default_model: local-gpt/gpt-5.6-luna
model_roles:
  approval: local-gpt/gpt-5.6-luna
approval:
  mode: ai                 # manual | ai | never | trusted
  failure_policy: ask_user # ask_user | deny，永远不会失败后自动批准
  timeout_ms: 30000
  log_decisions: true
  reviewer:
    model: local-gpt/gpt-5.6-luna
    reasoning_effort: medium
  policy:
    allow_workspace_writes: true
    ask_on_network: true
    ask_on_outside_workspace_write: true
    ask_on_destructive_commands: true
```

模型选择顺序为 `model_roles.approval`、`approval.reviewer.model`、默认模型。
`ask_user` 会回到现有 Allow once / Deny 终端卡片；AI 批准只对参数 hash 对应的
单次 operation 生效，不会创建永久或 session 白名单。Reviewer 的 system prompt
位于 `agent_product/src/approval_reviewer.cj`。

开发树中的可执行文件必须通过 `scripts/pinned_cangjie` 启动；该 wrapper 同时准备
`process4cj` 的平台后端并设置本次进程所需的动态库搜索路径。正式候选包由
`scripts/package_candidate.sh` 生成，二进制使用 `$ORIGIN/../lib` 相对 RPATH，包内
动态库使用 `$ORIGIN`，因此不得依赖全局 `LD_LIBRARY_PATH` 或主机绝对路径。

## 产品包

| 包 | 职责 |
| --- | --- |
| `agent_domain` | 协议无关领域值、`Result<T>`、预算、事件和审批 |
| `agent_protocol` | 与传输无关的 JSON-RPC 2.0 值、编解码和关联状态 |
| `agent_ports` | 模型、仓储、工作区、进程、审计等端口 |
| `model_adapters` | Agent `ModelRequest`/`ModelReply` 与独立仓库 `llm4cj` wire DTO 的语义映射及产品重试策略；依赖始终跟随其 `main` 分支 |
| `tool_runtime` | catalog → validation → policy → approval → receipt |
| `agent_core` | 唯一模型/工具循环 |
| `persistence_runtime` | 仓储实现、bounded events、schema 生命周期 |
| `sandbox_runtime` | fail-closed 工作区/进程/网络隔离、环境过滤和 secret 脱敏 |
| `run_control` | run 应用服务 |
| `task_runtime` | 独立 task 生命周期 |
| `subagent_runtime` | 使用同一 AgentCore 的结构化子任务 |
| `agent_mcp` | `mcp4cj` 产品配置、secret 解析、AgentError 映射和 ToolPipeline bridge |
| `agent_client` | CLI、CI、RPC、未来 cjtui 的稳定边界 |
| `agent_cli` | 类型化控制命令与自然 prompt 分流 |
| `agent_extensions` | `agent_sdk` 到 ToolPipeline 的产品 authority adapter，以及内部 trusted integration |
| `agent_embed` | 复用同一 AgentCore 的内部 `AgentBuilder`、Headless 与 JSONL 事件投影 |
| `agent_sdk` | 第三方协作式 Extension 的最小 metadata/schema/intent/output 公共契约 |
| `agent_extension_runtime` | 内部 manifest 校验、兼容性与 Extension 生命周期控制面 |
| `extensions/*` | 仅依赖 `agent_sdk`/通用库的 first-party cooperative extensions；当前包括 workspace search/write、AST 与 Web Search |
| `axyndra_agent_testkit` | 第三方安全的 SDK extension contract、确定性时钟/ID/取消与实验性 fault plan |
| `agent_testkit` | omp 内部 Agent/ToolPipeline/recovery doubles 与 benchmark 聚合 |
| `agent_product` | composition root、本地安全工具和磁盘基础设施 |
| `agent_rpc` | JSONL RPC server 与进程隔离 transport |
| `agent_tui` | 只依赖窄前端端口的 cjtui 界面 |
| `agent_app` | REPL、单次运行、恢复、RPC 与 TUI 可执行入口 |

完整依赖方向和约束见 [docs/architecture.md](docs/architecture.md)，能力状态、
安全边界和验证口径见 [docs/runtime-capabilities.md](docs/runtime-capabilities.md)。

## cjtui 与本地命令

无参数运行发行包中的 `bin/axyndra` 即进入 cjtui。界面通过 `ApplicationSession` 调用产品，
模型与工具在后台执行；流式文本、reasoning、工具、审批和 token 用量增量刷新。
运行中继续输入会进入 steer 队列。`Esc` 先关闭补全，再中断运行中的请求；
`Ctrl+C` 第一次清空编辑器、第二次退出，空编辑器也可用 `Ctrl+D` 退出。
`Tab` 第一次打开命令、子命令或路径候选，第二次 `Tab` 或 `Enter` 接受当前项，
`Esc` 取消候选。候选超过五项时会围绕当前项滚动，`Ctrl+L` 重置显示，`Ctrl+Z` 挂起进程，
`Ctrl+O` 与 `Ctrl+T` 分别切换工具输出和 thinking 的可见性。

普通输入支持相对路径、绝对路径和 `~/` 补全；slash 命令中仅 `/import`、
`/export`、`/todo import` 和 `/todo export` 的路径参数启用路径补全。含空格路径会自动使用双引号：
文件补全闭合引号，目录保留开放引号以便继续下钻。dotfile 只有在当前文件名前缀以 `.` 开头时显示。
未闭合双引号的 slash 命令会以 `cli.unterminated_quote` 留在本地编辑器中，不会执行或发送给模型。

当前补全只包含可执行命令：`/help`、`/setup`、`/providers`、`/model`、
`/switch`、`/login`、`/logout`、`/new`、`/clear`、`/session`、`/branch`、
`/fork`、`/compact`、`/handoff`、`/export`、`/dump`、`/todo`、`/rename`、
`/import`、`/reset`、
`/settings`、`/theme`、`/tools`、`/cancel`、`/agents`、`/jobs`、`/usage`、
`/stats`、`/exit`、`/quit`。`/login` 从配置指定的环境变量导入权限为 `0600`
的 provider 凭据；
审批可用
`/approve`、`/approve-session` 或 `/reject <reason>`。未知斜杠命令在本地报错，
不会发送给模型。

`/plan [request]` 进入只读 Plan Mode，结构化计划可通过 `/plan-review` 审阅。
在存在最新 `plan_write` 计划时，也可用独立短句直接批准并开始新的执行运行：
`执行吧`、`开始执行`、`执行计划`、`按计划执行`、`批准并执行`、`继续执行`，
以及 `execute`、`execute it`、`execute the plan`、`start execution`、
`approve and execute`、`proceed with execution`。仅匹配完整短句（允许一个句末感叹号或句号）；
否定、疑问和带附加条件的长句仍交给规划模型，不会隐式授权工具。

`/dump` 输出会话 transcript，并在临时目录写入标记为
`reconstructed_current_request` 的当前请求重建 JSON。它包含当前有效的 system prompt、thinking level、
work mode 和 capability 过滤后的工具，但不是历史 provider wire request 的原始抓包。

`/theme` 会打开主题选择器，也可用 `/theme <name>` 直接切换。内置主题和
`$AXYNDRA_HOME/themes/*.json` 中的自定义主题使用同一个注册表；
配置格式见 [主题说明](docs/themes.md)。

完整产品门禁：

```sh
bash scripts/release_gate.sh
```
