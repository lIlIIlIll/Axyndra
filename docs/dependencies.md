# 依赖与 stdx 审计

这份文档记录 Axyndra 为切换 Wirestack、sse4cj 和 yjson 所做的依赖审计。它描述当前工作树的源码、manifest、lockfile、构建脚本和可执行契约；llm4cj v0.2.0 已按独立仓库的 v0.2.0 release tag 和精确 commit pin 接入 model_adapters，但 Axyndra 的 SDK/产品门禁仍以当前工作树的可执行证据为准，不把未运行的 gate 写成已通过。

## 审计口径

外部 API 和 stdx 迁移审计的原始参照是 revision `9a532b5325a8b309c45280a4071e95a16881a886`。下文的 Workspace 包清单、发布分类和直接依赖已按 Issue #45 当前工作树更新；末节明确标出的旧审计结果只作历史记录。运行验收以[实施记录](issue-45-draft-status.md)中的实际证据为准。

数据来源分为四层：

1. 根 `cjpm.toml` 的 `workspace.members` 定义当前 39 个成员。独立 `plugins/*` 包另行构建，不计入宿主 workspace。
2. 每个 workspace 包的 `cjpm.toml` 定义直接依赖、来源类型、输出类型和 native/link 元数据；`packaging/public-packages.toml` 定义发布分类和公开运行要求。
3. 根及包级 `cjpm.lock` 定义可复现的远程 pin。源码 API 对照分别来自已锁定的 yjson/llm4cj 源码和相邻候选库工作树；候选工作树不是 Axyndra 当前依赖。
4. `.cj` 的 import、process 调用、构建脚本和 support test manifest 用来区分源码依赖、传递依赖、宿主工具和运行时前置条件。源码匹配不等于编译、链接或运行验收通过。

当前实际运行的 pin gate 核对 31 个 llm4cj lock、95 个 yjson lock 和 107 个 yjson manifest。`scripts/dependency_pin_gate.py` 验证这些 manifest 和 lock 中的 git、tag、commitId 一致性。只声明 yjson 的闭包不要求出现 llm4cj 行；实际声明 llm4cj 的闭包使用统一的 tag 和 commit。

## 外部来源与完整 pin

| 依赖 | Axyndra 当前声明 | 锁定来源 | 需要单独核对的候选来源 |
| --- | --- | --- | --- |
| yjson | Git，静态输出，tag = "0.1.0" | https://github.com/lIlIIlIll/yjson.git，commit c91859feb77aeba392a1fad0f99d731df66be831，tag = "0.1.0" | 该 release 的生产 dependencies 为空，仅在 test-dependencies 以 commit fec0adce41f73d037d876cbac7a28aee8108bb5c 引入 yjson_macros。 |
| llm4cj | Git，静态输出，tag = "v0.2.0" | https://github.com/lIlIIlIll/llm4cj.git，commit fd83641c4f39fc5c299298187028e581e7a8616c，tag = "v0.2.0" | release manifest 同样声明 yjson tag = "0.1.0"；其 src/json_support.cj 使用 JsonNode.parse、JsonReadOptions 和公开容器访问。 |
| `Wirestack` | 当前未声明 | 相邻工作树 `../Wirestack`，未加入根 workspace | HTTP/TLS/native API 只能在迁移规格中作为候选接口。它的 native resolver/TLS-provider 物料、SDK 组合和动态库闭包仍需运行验证。 |
| `sse4cj` | 当前未声明 | 相邻工作树 `../sse4cj`，未加入根 workspace | decoder 与 stdx HTTP/server 在同一个包中，且 manifest 带 stdx bin-dependency；不能只因 decoder API 相似就宣称去除 stdx。 |
| yjson_algorithms | 不再作为独立依赖 | yjson 0.1.0 tag 中的算法源码已嵌入 libs/yjson_support，并随该 package 发布 | GitHub 未提供可单独 pin 的仓库；当前 schema、JSON Pointer、JSON Path 和 JSON Patch 行为来自已验证的 yjson tag 源码。 |

`model_adapters/cjpm.toml` 的声明：

```toml
llm4cj = {git = "https://github.com/lIlIIlIll/llm4cj.git", tag = "v0.2.0", output-type = "static"}
```

对应 lock 的解析：

```toml
llm4cj = {git = "https://github.com/lIlIIlIll/llm4cj.git", commitId = "fd83641c4f39fc5c299298187028e581e7a8616c", tag = "v0.2.0", output-type = "static"}
```

yjson 使用 release tag 0.1.0，锁文件将其解析为 commit c91859feb77aeba392a1fad0f99d731df66be831；llm4cj 使用 release tag v0.2.0，解析为 commit fd83641c4f39fc5c299298187028e581e7a8616c。这样既保留可复现的 commit，又让 manifest 与已验证的 release 依赖声明一致；JSON schema 算法源码随 yjson tag 嵌入 libs/yjson_support。

## Workspace 包清单

下表从根 workspace 和每个成员的生产 manifest 计算。`[path]` 表示仓内 path dependency，`[git:yjson pin]` 和 `[git:llm4cj pin]` 指向上表的精确版本，`[vendor path]` 表示 `vendor/cj_tui` 包。发布分类与 `packaging/public-packages.toml` 一致；实际执行 `python3 scripts/package_readiness.py audit` 得到 9 个 public、1 个 held、29 个 internal。`libs/logical_json_payload`、`agent_host_runtime` 和 `model_fixture_runtime` 属于 internal，不新增公开包或发布兼容性承诺。

| 包目录 | 发布分类 | 直接依赖（来源类型） | native/link 要求 |
| --- | --- | --- | --- |
| `agent_plugin_registry` | internal/packages | `agent_domain` [path]；`agent_sdk` [path]；`agent_extension_runtime` [path]；`yjson_support` [path]；`yjson` [git:yjson pin] | `target.x86_64-unknown-linux-gnu.bin-dependencies.path-option = ["${CANGJIE_STDX_PATH}"]` |
| `agent_history` | internal/packages | `agent_domain` [path]；`agent_runtime` [path]；`agent_store` [path]；`agent_app_protocol` [path]；`yjson_support` [path]；`yjson` [git:yjson pin] | `package.link-option = "-lsqlite3"`；`target.x86_64-unknown-linux-gnu.bin-dependencies.path-option = ["${CANGJIE_STDX_PATH}"]` |
| `agent_minimal` | internal/packages | `agent_core` [path]；`agent_host_runtime` [path]；`agent_runtime` [path]；`agent_ports` [path]；`tool_runtime` [path]；`persistence_runtime` [path]；`process4cj` [path]；`agent_extension_runtime` [path]；`agent_plugin_registry` [path]；`agent_history` [path]；`agent_store` [path]；`agent_domain` [path]；`agent_app_protocol` [path]；`yjson_support` [path]；`yjson` [git:yjson pin] | `package.link-option = "-lsqlite3"`；`target.x86_64-unknown-linux-gnu.bin-dependencies.path-option = ["${CANGJIE_STDX_PATH}"]` |
| `libs/yjson_support` | generic | `yjson` [git:yjson pin] | — |
| `libs/logical_json_payload` | internal/packages | `yjson` [git:yjson pin]；`yjson_support` [path] | `target.x86_64-unknown-linux-gnu.bin-dependencies.path-option = ["${CANGJIE_STDX_PATH}"]` |
| `libs/jsonrpc4cj` | generic | `yjson` [git:yjson pin]；`yjson_support` [path] | — |
| `libs/mcp4cj` | generic | `yjson` [git:yjson pin]；`yjson_support` [path]；`jsonrpc4cj` [path]；`process4cj` [path] | `target.x86_64-unknown-linux-gnu.bin-dependencies.path-option = ["${CANGJIE_STDX_PATH}"]` |
| `libs/process4cj` | generic | — | C FFI `process4cj_native` [path=`native`]；`target.x86_64-unknown-linux-gnu.bin-dependencies.path-option = ["native"]` |
| `libs/sandbox4cj` | generic | `process4cj` [path] | — |
| `libs/skill_runtime` | hold/experimental | `yjson` [git:yjson pin]；`yjson_support` [path] | — |
| `libs/lsp4cj` | generic | `yjson` [git:yjson pin]；`yjson_support` [path]；`jsonrpc4cj` [path]；`process4cj` [path] | — |
| `libs/dap4cj` | generic | `yjson` [git:yjson pin]；`yjson_support` [path]；`process4cj` [path] | — |
| `agent_domain` | internal/packages | `logical_json_payload` [path]；`yjson` [git:yjson pin]；`yjson_support` [path]；`process4cj` [path] | `target.x86_64-unknown-linux-gnu.bin-dependencies.path-option = ["${CANGJIE_STDX_PATH}"]` |
| `agent_app_protocol` | internal/packages | `agent_domain` [path] | — |
| `agent_skills` | internal/packages | `yjson_support` [path]；`yjson` [git:yjson pin]；`agent_domain` [path]；`skill_runtime` [path] | — |
| `agent_runtime` | internal/packages | `logical_json_payload` [path]；`yjson_support` [path]；`yjson` [git:yjson pin]；`agent_domain` [path] | `target.x86_64-unknown-linux-gnu.bin-dependencies.path-option = ["${CANGJIE_STDX_PATH}"]` |
| `agent_store` | internal/packages | `yjson_support` [path]；`yjson` [git:yjson pin]；`agent_domain` [path]；`agent_ports` [path]；`agent_runtime` [path] | `package.link-option = "-lsqlite3"`；`target.x86_64-unknown-linux-gnu.bin-dependencies.path-option = ["${CANGJIE_STDX_PATH}"]` |
| `agent_protocol` | internal/packages | `yjson_support` [path]；`yjson` [git:yjson pin]；`agent_domain` [path]；`jsonrpc4cj` [path] | — |
| `agent_ports` | internal/packages | `yjson` [git:yjson pin]；`agent_domain` [path]；`yjson_support` [path] | — |
| `agent_core` | internal/packages | `logical_json_payload` [path]；`yjson_support` [path]；`yjson` [git:yjson pin]；`agent_domain` [path]；`agent_runtime` [path]；`agent_ports` [path]；`tool_runtime` [path] | — |
| `agent_host_runtime` | internal/packages | `model_provider_runtime` [path]；`agent_core` [path]；`agent_plugin_registry` [path]；`agent_sdk` [path]；`process4cj` [path]；`sandbox4cj` [path]；`agent_extension_runtime` [path]；`agent_domain` [path]；`agent_runtime` [path]；`agent_ports` [path]；`agent_store` [path]；`tool_runtime` [path]；`yjson_support` [path]；`yjson` [git:yjson pin] | `package.link-option = "-lsqlite3"`；`target.x86_64-unknown-linux-gnu.bin-dependencies.path-option = ["${CANGJIE_STDX_PATH}"]` |
| `tool_runtime` | internal/packages | `agent_domain` [path]；`agent_runtime` [path]；`agent_ports` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | — |
| `persistence_runtime` | internal/packages | `agent_runtime` [path]；`yjson_support` [path]；`yjson` [git:yjson pin]；`agent_domain` [path]；`agent_ports` [path]；`agent_store` [path] | `package.link-option = "-lsqlite3"`；C FFI `process4cj_native` [path=`../libs/process4cj/native`]；`target.x86_64-unknown-linux-gnu.bin-dependencies.path-option = ["../libs/process4cj/native", "${CANGJIE_STDX_PATH}"]` |
| `run_control` | internal/packages | `agent_core` [path]；`agent_runtime` [path]；`agent_domain` [path]；`agent_ports` [path] | — |
| `task_runtime` | internal/packages | `agent_domain` [path] | — |
| `agent_client` | internal/packages | `agent_core` [path]；`agent_runtime` [path]；`agent_domain` [path]；`run_control` [path] | — |
| `agent_cli` | internal/packages | `yjson_support` [path]；`yjson` [git:yjson pin]；`agent_domain` [path] | — |
| `model_adapters` | internal/packages | `agent_domain` [path]；`agent_ports` [path]；`yjson` [git:yjson pin]；`yjson_support` [path]；`llm4cj` [git:llm4cj pin]；`process4cj` [path] | `target.x86_64-unknown-linux-gnu.bin-dependencies.path-option = ["${CANGJIE_STDX_PATH}"]` |
| `model_provider_runtime` | internal/packages | `agent_domain` [path]；`agent_ports` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | — |
| `agent_embed` | internal/packages | `yjson` [git:yjson pin]；`yjson_support` [path]；`agent_domain` [path]；`agent_ports` [path]；`agent_runtime` [path]；`agent_core` [path]；`tool_runtime` [path] | `target.x86_64-unknown-linux-gnu.bin-dependencies.path-option = ["${CANGJIE_STDX_PATH}"]` |
| `agent_sdk` | ecosystem | `yjson` [git:yjson pin]；`yjson_support` [path] | — |
| `agent_extension_runtime` | internal/packages | `agent_domain` [path]；`agent_sdk` [path]；`process4cj` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | `target.x86_64-unknown-linux-gnu.bin-dependencies.path-option = ["${CANGJIE_STDX_PATH}"]` |
| `axyndra_agent_testkit` | ecosystem | `agent_sdk` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | — |
| `model_fixture_runtime` | internal/packages | `yjson` [git:yjson pin]；`yjson_support` [path]；`agent_domain` [path]；`agent_ports` [path] | — |
| `agent_testkit` | internal/packages | `yjson_support` [path]；`yjson` [git:yjson pin]；`model_fixture_runtime` [path]；`agent_domain` [path]；`agent_ports` [path]；`agent_runtime` [path]；`tool_runtime` [path] | — |
| `agent_product` | internal/packages | `logical_json_payload` [path]；`agent_host_runtime` [path]；`agent_plugin_registry` [path]；`agent_history` [path]；`model_fixture_runtime` [path]；`model_provider_runtime` [path]；`agent_cli` [path]；`agent_app_protocol` [path]；`agent_client` [path]；`agent_core` [path]；`agent_domain` [path]；`agent_protocol` [path]；`agent_ports` [path]；`agent_runtime` [path]；`agent_sdk` [path]；`agent_extension_runtime` [path]；`agent_store` [path]；`yjson` [git:yjson pin]；`yjson_support` [path]；`persistence_runtime` [path]；`process4cj` [path]；`run_control` [path]；`sandbox4cj` [path]；`task_runtime` [path]；`tool_runtime` [path] | `package.link-option = "-lsqlite3"`；`target.x86_64-unknown-linux-gnu.bin-dependencies.path-option = ["${CANGJIE_STDX_PATH}"]` |
| `agent_rpc` | internal/packages | `agent_runtime` [path]；`logical_json_payload` [path]；`agent_embed` [path]；`yjson_support` [path]；`yjson` [git:yjson pin]；`agent_cli` [path]；`agent_core` [path]；`agent_product` [path]；`agent_domain` [path]；`tool_runtime` [path] | `package.link-option = "-lsqlite3"`；`target.x86_64-unknown-linux-gnu.bin-dependencies.path-option = ["${CANGJIE_STDX_PATH}"]` |
| `agent_tui` | internal/packages | `logical_json_payload` [path]；`agent_domain` [path]；`agent_cli` [path]；`core` [vendor path]；`markdown` [vendor path] | — |
| `agent_app` | internal/packages | `agent_host_runtime` [path]；`logical_json_payload` [path]；`agent_runtime` [path]；`yjson_support` [path]；`yjson` [git:yjson pin]；`agent_cli` [path]；`agent_app_protocol` [path]；`agent_client` [path]；`agent_core` [path]；`agent_domain` [path]；`agent_product` [path]；`agent_rpc` [path]；`agent_embed` [path]；`agent_tui` [path]；`core` [vendor path]；`process4cj` [path]；`tool_runtime` [path] | `package.link-option = "-lsqlite3"` |

当前 32 个 workspace 成员直接声明 yjson。`agent_sdk` 的直接依赖仍只有 yjson 和 `yjson_support`，没有引入产品执行权限。静态依赖的链接选项不自动传播到聚合 unittest executable；所有声明 SQLite 的成员仍保留原有 `-lsqlite3`。`agent_rpc` 的生产 manifest 不再直接依赖 `agent_store`，持久化访问经过 Product；原有 SQL 行与 receipt 测试断言没有删除。新 manifest 的实际 RPC 编译和运行验收仍以实施记录为准。

## workspace 外的包和测试闭包

### Vendored cjtui

`vendor/cj_tui` 不属于根 workspace。当前可读到三个 manifest：

- `vendor/cj_tui/packages/core` 无依赖。
- `vendor/cj_tui/packages/cj_markdown` 无依赖。
- `vendor/cj_tui/packages/markdown` 依赖同目录的 `core` 和 `cj_markdown`。

根 workspace 只有 `agent_tui` 和 `agent_app` 直接使用其中的 `core`；`agent_tui` 还使用 `markdown`。这些路径不是新的 stdx 依赖。

### 独立进程插件

`plugins/ast` 和 `plugins/web_search` 分别声明 `ast_plugin` 和 `web_search_plugin`，由独立 manifest 构建，不加入根 workspace，也不被宿主 path 依赖。AST 使用通用只读进程和文件计划服务，Web 使用预先冻结请求的通用 HTTP 服务；业务 schema、provider 选择和结果转换位于插件。两包都随独立交付物携带所需非系统动态库，AST 另携带锁定的 ast-grep engine。宿主的 `process4cj`、隔离和 HTTP 传输仍是通用基础设施依赖。

旧 `extensions/ast_extension` 和 `extensions/web_search_extension` 已删除。旧 MCP 静态适配层已从生产图移除；安装与兼容行为须按 `docs/mcp-plugin-migration.md` 独立验收。独立插件也由 `plugin_boundary_gate.py` 纳入依赖图及禁止宿主依赖的分类；包数量与当前依赖图以重新运行的 boundary gate 输出为准。

### 独立 sandbox experiment

`sandbox_runtime` 有自己的 manifest 和实现，不在根 `members`、`build-members` 或 `test-members` 中。它只通过 path 使用 `agent_domain` 和 `libs/sandbox4cj`，必须单独构建和验证。`subagent_runtime` 只有说明和迁移占位内容，不是当前可构建包。

### support_tests

当前可读到 64 个 `support_tests/*/cjpm.toml`。它们不是根 workspace member，但大量通过 path 递归使用生产包，并在自己的 manifest 中复制 yjson pin。需要把测试包的 path 目标解析到真实 manifest，不能把 support-test 的父目录或同名 sibling 项目当成产品依赖。

与 stdx 和这次候选迁移直接相关的测试入口如下：

| 生产消费者 | 直接使用或覆盖它的 support test | 触发的证据 |
| --- | --- | --- |
| `mcp4cj` | `support_tests/mcp_conformance_server`、`support_tests/native_provider_security_contract` | MCP conformance、原生 provider 安全和 HTTP/TLS 运行路径 |
| `process4cj` | `support_tests/sqlite_run_repository_contract`、`support_tests/thread_runtime_contract` | SQLite repository 和 thread runtime 的 process/cancellation 交互 |
| `model_adapters` | `support_tests/acp_lifecycle_contract`、`support_tests/artifact_contract`、`support_tests/direct_runtime_sandbox_contract`、`support_tests/gc_contract`、`support_tests/handoff_request_contract`、`support_tests/model_adapters_contract`、`support_tests/native_provider_security_contract`、`support_tests/product_continuation_contract`、`support_tests/product_contract`、`support_tests/product_prompt_contract`、`support_tests/product_rpc_contract`、`support_tests/product_thread_runtime_contract` | provider wire、凭据安全、retry/fallback、产品和 runtime 组合 |
| `agent_product` | 产品、MCP、GitHub、sandbox、RPC、continuation、memory、prompt 等相关 contracts，以及 `PluginHttp*` 真实 HTTP 单元 | composition root 对工具和 runtime 的组合证据 |

其中所列 support-test manifest 显式声明 `${CANGJIE_STDX_PATH}`：`checkpoint_compaction_contract`、`mcp_conformance_server`、`mcp_contract`、`native_provider_security_contract` 和 `prompt_memory_v3_contract`。只有两处 support-test 源码直接 import stdx：`support_tests/mcp_contract/src/main.cj` 和 `libs/mcp4cj/src/mcp_test.cj`；其他测试通过被测包的 target 和传递依赖获得构建要求。

两个需要递归解析的跨测试目录 path dependency 是 `support_tests/extension_runtime_contract` 和 `support_tests/sdk_fixture_extension_runner` 对 `../sdk_fixture_extension` 的引用。它们不是根 workspace package，也不能被文档清单遗漏。

## stdx 使用清单

### 源码 import

当前直接 import stdx 的生产源码只有 2 个文件，分布在 2 个直接源码消费者中：

| 源文件 | stdx API | 当前职责 |
| --- | --- | --- |
| `model_adapters/src/native_transport.cj` | `stdx.log.NoopLogger`、`stdx.net.http.*`、`stdx.net.tls.*` | `NativeProviderTransport` 的 provider HTTP、TLS、body 读取、取消、凭据阶段和错误映射 |
| `libs/mcp4cj/src/http.cj` | `stdx.log.NoopLogger`、`stdx.net.http.*`、`stdx.net.tls.*` | `StreamableHttpMcpTransport` 的 request-scoped HTTP、SSE response、取消和 MCP header 处理 |

安全随机数消费者 `model_adapters/src/adapters.cj`、`agent_product/src/product.cj` 和 `agent_product/src/process_broker.cj` 已统一使用 `process4cj.fillSecureRandom`；它们不再依赖 `stdx.crypto`。

直接 stdx import 的测试文件是 `libs/mcp4cj/src/mcp_test.cj` 和 `support_tests/mcp_contract/src/main.cj`。历史适配层已删除，不计入当前源码使用数。

对应 manifest 中明确设置 `${CANGJIE_STDX_PATH}` 的所列 workspace 包是 `libs/mcp4cj`、`model_adapters` 和 `agent_product`。`libs/process4cj` 的 target path 是 `native`，它是 C shim 的本地物料，不应误计为 stdx path。

### 传递闭包
从两个直接 stdx 源码消费者沿 workspace manifest 的反向依赖闭包计算，受 stdx 影响的 8 个 workspace 包是：

```text
agent_app
agent_product
agent_rpc
libs/mcp4cj
model_adapters
persistence_runtime
```

`agent_domain` 虽然直接依赖 `process4cj`，并通过 `process4cj as process` 使用取消相关类型，但它没有直接 import stdx。反过来，四个直接 target 配置、SDK 路径解析和打包脚本仍使 stdx 成为全局构建/发布前置；因此“源码 import 清零”不等于“构建和发行包不再需要 stdx”。

### SDK、CI 和打包硬要求

- `scripts/sdk_paths.sh` 只有在目标 stdx 目录存在 `libstdx.net.http.so` 时才接受它。`CANGJIE_STDX_PATH` 是 fallback，匹配选定 SDK 的相邻 stdx 时优先使用相邻目录。
- `scripts/pinned_cangjie` 先通过 `scripts/check_sdk.sh` 校验 SDK，再解析 stdx，设置 `CANGJIE_STDX_PATH`，并无条件调用 `scripts/prepare_native_deps.sh`。
- `scripts/check_native_compiler.sh` 是 native compiler validation 的单一入口：它使用 `AXYNDRA_NATIVE_CC` 或 `PATH` 中的 `clang`，要求 LLVM/Clang >= 15，并执行 C11/Linux capability probe。开发构建和 source-package staging 都在编译 `process4cj_native.c` 前调用该检查；LLVM 15 是 reference/release baseline，而非唯一兼容版本。
- `scripts/package_candidate.sh` 先验证 SDK、完整 stdx、构建出的产品 executable 和 `patchelf`，再以 `ldd` 递归收集 process-native、SDK、tools 和 stdx 动态库，并检查最终诊断中没有 `not found`。
- `.github/workflows/pr-gate.yml` 以 LLVM 15 和 STS 1.1.3 作为 reference baseline；nightly gate 以匹配的 nightly SDK/stdx 和 LLVM 18 覆盖前向兼容，并把 SDK/stdx 检查放在构建测试之前。

`process4cj.fillSecureRandom` 是 ProductIds、retry jitter 和 broker token 的现有安全随机实现，底层使用 Linux getrandom C ABI；它已从 stdx.crypto 解耦，但仍属于最终 native 物料闭包。

## 非 stdx 的系统要求

下表只列源码和脚本已经明确的消费者与触发条件。可选工具不是所有用户的安装前提；功能被启用时仍必须满足对应 executable 或库要求。

| 要求 | 消费者与触发功能 | 证据和范围 |
| --- | --- | --- |
| Linux x86_64 + glibc；支持 C11/Linux headers 的 Clang | `process4cj` 运行时；所有使用本地 process backend 的产品/合同 | `packaging/public-packages.toml` 将 `process4cj` 标为 `linux-x86_64`、`glibc`；其 C shim 使用 `AXYNDRA_NATIVE_CC` 或从 `PATH` 发现的 `clang` 构建。 |
| SQLite | `agent_store`、`agent_history`、`agent_minimal`、`agent_host_runtime`、`persistence_runtime`、`agent_product`、`agent_rpc`、`agent_app` 及相应聚合合同 | 这些成员 manifest 保留 `link-option = "-lsqlite3"`；静态依赖的链接选项不自动传递。 |
| bubblewrap | `sandbox4cj` / `agent_product` 的 workspace sandbox | `libs/sandbox4cj/src/sandbox.cj` 默认使用 `/usr/bin/bwrap`，并验证 namespace 隔离；Linux 或 bubblewrap 不可用时返回 `Unsupported`，不退回裸执行。 |
| `timeout` | sandbox command 的 deadline wrapper | 默认 executable 为 `/usr/bin/timeout`；缺失时 sandbox availability 失败。 |
| `prlimit` | 仅当 `SandboxResourceLimits` 启用 address-space、file-size、open-files、processes 或 CPU limit | sandbox command 会在配置了 process limits 时加入 `/usr/bin/prlimit`；默认不因未配置资源上限而要求它。 |
| `curl` | 通用插件 `network.http` 受控服务 | 固定 `/usr/bin/curl`，首参数 `-q`，通过只读隔离 ProcessPort 和 Mediated gateway 执行已批准意图，无自动重定向/重试；秘密只在宿主按 operator grant 注入。Brave/Tavily/SearxNG 算法属于独立 `plugins/web_search`，宿主不选择 provider，默认目录没有网页搜索工具。 |
| `git`、`gh` | GitHub tool 的 repo/file/PR/Actions 操作，及 worktree runtime | `ProductGithubRuntime` 默认解析 `/usr/bin/gh`、`/usr/local/bin/gh`、`/usr/bin/git`、`/usr/local/bin/git`；`gh api` 读文件，`gh pr` 做 checkout，`git push` 走显式批准的写操作。缺失只影响这些功能，不是基础 Agent loop 的所有用户前置。 |
| ripgrep (`rg`) | `grep` 和 `glob` 产品工具 | `agent_product/src/tools.cj` 以 `rg` argv 执行 workspace search/file listing，带只读 sandbox、超时和输出限制；产品未把它写成固定 `/usr/bin/rg`，由宿主 PATH 提供。 |
| `ast-grep` | 独立 `plugins/ast` 查询与编辑提案 | 插件随包携带固定摘要的 engine，经通用 `process.readonly` 执行；默认产品没有 AST 工具或系统 ast-grep 依赖。编辑只产生只读提案，交由通用 `file.plan.propose` 存储，实际变更另走既有 `apply_file_plan` 审批。 |
| `/bin/bash`、`/bin/sh`、`script` | `bash` 工具、clipboard staging、pty 分支 | shell 工具用 `/bin/bash --noprofile --norc -lc`；pty 分支使用 `script` 包装；clipboard 的可信 UI 边界使用 `/bin/sh` 和系统 clipboard 命令。它们受产品 process/sandbox policy，不等同于允许模型直接突破边界。 |
| Python、Bun、Ruby、Julia | `eval` 工具按语言选择 `/usr/bin/python3`、`/usr/bin/bun`、`/usr/bin/ruby`、`/usr/bin/julia` | 仅启用对应 eval 语言时需要；eval 请求仍进入 workspace read-write sandbox 和输出/超时限制。 |
| LSP server executable | installed `axyndra:lsp` service | [插件配置](../plugins/lsp/src/configuration.cj) 校验工作区 URI、语言、初始化选项、settings 和请求超时；[会话实现](../plugins/lsp/src/session.cj) 经受控 process channel 与语言服务器通信。语言服务器由部署配置供应，不再由 Product 内建 LSP runtime 解析业务配置。 |
| DAP executable | installed `axyndra:dap` service | `plugins/dap` selects the configured adapter and its exact arguments. The installed service requests process work through the existing canonical Host; there is no Product built-in DAP executor. Current binary parity and cleanup tests remain required. |
| MCP stdio server executable | `mcp4cj` 独立库/插件 的 stdio transport | MCP 配置提供 executable、argv 和显式环境 binding；长生命周期子进程由 process4cj 管理。Streamable HTTP 则使用 stdx HTTP，不要求 MCP library 固定一个 server executable。 |
| SSH executable | 当前 `/ssh` 配置命令 | `agent_product/src/ssh_runtime.cj` 当前读写 project/user 的 `ssh.json`，源码没有把 `ssh` executable 接入这条配置管理路径。因此 SSH host 配置不是本轮可证明的 SSH 子进程运行要求；不要把它写成所有用户的安装前提。 |
| `patchelf`、`ldd`、可用 `awk`/`grep` | `scripts/package_candidate.sh` | `patchelf` 是 relocatable candidate 的硬要求；`ldd` 用于递归动态库闭包和最终缺库检查，`rp-awk`/`rp-grep` 不存在时脚本回退到系统 `awk`/`grep`。 |

Wirestack 若进入后续迁移，还需要其 manifest 声明的 resolver/TLS-provider native 物料以及 `-lstdc++ -lpthread -ldl -lm`。`python3 -B ../Wirestack/tools/build_native_dependencies.py --plan` 只输出 native 构建计划；输出 `READY` 不等于物料已经构建、SDK 兼容或 HTTPS 已验收。

## JSON 和取消边界

当前 JSON 不是首次替换 stdx JSON。Axyndra 的适配 seam 是 `libs/yjson_support/src/json_support.cj`：

- `AgentValue` 在 `agent_domain/src/domain.cj` 中就是 `JsonNode`，SDK 公开字段和参数也直接使用 JsonNode。
- UnifiedJsonAccess 把 yjson 的 JsonKind 归一化为 Null/Boolean/Number/Text/List/Object，集中提供 field、put、add、stringify、parseUnifiedJson 和 schema 错误投影。
- items 返回基于 yjson array 内容的稳定 live alias；这是当前可观察行为，不能改成 snapshot 后仍声称无损替换，也不能要求 yjson 暴露私有 backing storage。
- yjson tag 的公开容器访问使用 JsonArray.size/get/add/insert 和 JsonObject.size/nameAt/valueAt/put；适配层只在 JsonNode seam 上保留 put/add 兼容方法，不能直接调用包内的 values()/entries()。
- schema、JSON Pointer、JSON Path 和 JSON Patch 适配由 yjson tag 中嵌入的算法源码提供，适配层再把 violation path/keyword 映射回现有合同；不能要求通用 JSON 库理解 Axyndra 的业务字段。

`agent_domain/src/v3_control.cj` 使用 `process4cj as process` 参与 cancellation/runtime 类型适配；这与 `agent_domain` 没有 stdx import 是两个不同层次的事实。架构文档必须同时保留这两个事实，不能为了画出纯领域图而反向修改 manifest。

## 静态验证结果与限制

本轮文档审计的只读门禁如下，不调用会生成 SDK cache、native shim 或 build directory 的 `scripts/pinned_cangjie`：

```sh
python3 -B scripts/dependency_pin_gate.py
python3 -B scripts/check_library_boundaries.py
python3 -B scripts/docs_gate.py
bash scripts/architecture_gate.sh
```

完整架构门禁检查生产模块边界，不固定内部 helper 的文件名或 worker 的局部变量名。Model/provider 的生产执行调用必须留在 `agent_core/src`；`*_test.cj` 和独立 `support_tests` 不作为生产入口。CLI 的退役命令检查也只扫描生产源码，不能把真实管道测试的子进程模式当作公开命令。异步物理回收、PeerMessage 权限和 RPC 的 SQL/Receipt 行为仍须通过各自原始运行用例；静态通过不能替代它们。

以下是原 revision 审计留下的历史结果，不表示当前 Issue #45 的完整门禁已经通过：

- dependency pin gate passed (35 llm4cj locks, 72 yjson locks, 72 yjson manifests, llm4cj tag=v0.2.0, yjson tag=0.1.0)；
- `reusable library boundaries passed (8 libraries)`；
- 当时的 docs gate 使用 38 个 workspace 包；当前 workspace 为 39 个成员。当前 gate 的实际结果见实施记录。

候选 Wirestack 目录存在时，可以只运行计划器：

```sh
python3 -B ../Wirestack/tools/build_native_dependencies.py --plan
```

本次审计记录的计划器输出是 `{"platform": "linux-x86_64-glibc", "status": "READY", "steps": ["tls-provider", "resolver"]}`。它只证明计划器识别出两类 native 输入。

原审计的一次性 TOML 解析得到 38 个 workspace 包、31 个直接声明 yjson 的成员，以及以下旧 stdx 传递闭包：

```text
agent_app
agent_extensions
agent_product
agent_rpc
libs/mcp4cj
model_adapters
persistence_runtime
```

这些静态结果不证明 SDK/stdx/native 组合可编译，不证明 Wirestack/sse4cj 的运行语义等价，也不证明真实 provider、MCP server、PTY、打包产物或目标平台已经通过。运行合同、输入、预期结果和现有测试入口见 [stdx 迁移执行规格](stdx-migration.md)。
