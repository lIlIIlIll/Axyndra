# 依赖与 stdx 审计

这份文档记录 Axyndra 为切换 Wirestack、sse4cj 和 yjson 所做的依赖审计。它描述当前工作树的源码、manifest、lockfile、构建脚本和可执行契约，不表示候选库已经接入，也不表示候选行为已经通过运行验收。

## 审计口径

审计参照是仓库 revision `9a532b5325a8b309c45280a4071e95a16881a886`。该 revision 对应的工作树包含未提交修改，因此本文把当前工作树的源码、manifest 和 CI 作为证据，不把 HEAD 之外的假设写成产品事实。本轮只新增和修正文档，不修改生产代码、测试、manifest、lockfile、CI 或候选库。

数据来源分为四层：

1. 根 `cjpm.toml` 的 `workspace.members` 定义生产包集合，共 38 个包。
2. 每个 workspace 包的 `cjpm.toml` 定义直接依赖、来源类型、输出类型和 native/link 元数据；`packaging/public-packages.toml` 定义发布分类和公开运行要求。
3. 根及包级 `cjpm.lock` 定义可复现的远程 pin。源码 API 对照分别来自已锁定的 yjson/llm4cj 源码和相邻候选库工作树；候选工作树不是 Axyndra 当前依赖。
4. `.cj` 的 import、process 调用、构建脚本和 support test manifest 用来区分源码依赖、传递依赖、宿主工具和运行时前置条件。源码匹配不等于编译、链接或运行验收通过。

当前树中可读到 72 个非 `.git` 的 `cjpm.lock`：根锁文件、13 个 workspace 包锁文件和 58 个 support-test 锁文件。它们的 lockfile `version` 均为 `0`；其中 36 个只包含 yjson，33 个包含 yjson 和 llm4cj，3 个没有远程 requires。所有含 yjson 的锁文件都使用同一个 commit，含 llm4cj 的锁文件也使用同一个 commit。`scripts/dependency_pin_gate.py` 只验证 llm4cj，不替代 yjson、yjson_macros 或 schema 来源审计。

## 外部来源与完整 pin

| 依赖 | Axyndra 当前声明 | 锁定来源 | 需要单独核对的候选来源 |
| --- | --- | --- | --- |
| `yjson` | Git，静态输出 | `https://github.com/lIlIIlIll/yjson.git`，commit `92858f75aedc3dd6f7322789117854514549e62c` | 可读到的锁定 manifest 自报 `1.0.0`，并含 `packages/yjson_macros` path 依赖。相邻 `../yjson/cjpm.toml` 自报 `0.1.0`，生产 dependencies 为空，只在 test-dependencies 以 commit `30c3def793054c4b5ba25be2e22598e141923a51` 引入 `yjson_macros`。两者不是同一份可替换证据。 |
| `llm4cj` | Git，静态输出，`branch = "main"` | `https://github.com/lIlIIlIll/llm4cj.git`，commit `62e6c57227630f2ccbc0f48fecfdf36a896e7e6d` | 锁定源码的 `src/json_support.cj` 仍调用 `YJson.parse`、`JsonReadConfig` 和 `JsonKind.Js*`；相邻 llm4cj 工作树已使用 `JsonNode.parse`、`JsonReadOptions` 和公开容器访问。`branch = "main"` 仍不是 pin，不能用相邻工作树替换已审阅 commit。 |
| `Wirestack` | 当前未声明 | 相邻工作树 `../Wirestack`，未加入根 workspace | HTTP/TLS/native API 只能在迁移规格中作为候选接口。它的 native resolver/TLS-provider 物料、SDK 组合和动态库闭包仍需运行验证。 |
| `sse4cj` | 当前未声明 | 相邻工作树 `../sse4cj`，未加入根 workspace | decoder 与 stdx HTTP/server 在同一个包中，且 manifest 带 stdx bin-dependency；不能只因 decoder API 相似就宣称去除 stdx。 |
| `yjson_algorithms` | 当前未声明独立来源 | 源码位于相邻 `../yjson/packages/yjson_algorithms`，其 manifest 使用 `yjson = { path = "../.." }` | 本轮两次 GitHub 仓库查询没有检出独立 `yjson_algorithms` 仓库。该结果只表示尚无可验证的独立来源和 pin，不证明不存在任何其他分发渠道。 |

根 `cjpm.lock` 的远程 pin 为：

```toml
yjson = {git = "https://github.com/lIlIIlIll/yjson.git", commitId = "92858f75aedc3dd6f7322789117854514549e62c", output-type = "static"}
llm4cj = {git = "https://github.com/lIlIIlIll/llm4cj.git", commitId = "62e6c57227630f2ccbc0f48fecfdf36a896e7e6d", branch = "main", output-type = "static"}
```

yjson 版本号在锁定源码和相邻工作树之间不同，不能把本次 API 整理描述为普通版本升级。JSON schema 的来源、yjson/macros 闭包和兼容的 llm4cj 修订必须一起确认；不能只改 `libs/yjson_support` 就宣布整个 JSON 闭包可升级。

## Workspace 包清单

下表由根 workspace 和每个成员 manifest 的 TOML 数据整理。依赖列中的 `[path]` 表示仓内 path dependency，`[git:yjson pin]` 和 `[git:llm4cj pin]` 分别指向上表的完整 commit；`vendor path` 是 `vendor/cj_tui` 下的本地包。分类值与 `packaging/public-packages.toml` 一致：`generic`、`ecosystem`、`hold/experimental` 和 `internal/packages`。

| 包目录 | 发布分类 | 直接依赖（来源类型） | native/link 要求 |
| --- | --- | --- | --- |
| `libs/yjson_support` | generic | `yjson` [git:yjson pin] | — |
| `libs/jsonrpc4cj` | generic | `yjson` [git:yjson pin]；`yjson_support` [path] | — |
| `libs/process4cj` | generic | — | C FFI `process4cj_native` [path=`native`]；x86_64 target bin path=`native` |
| `libs/mcp4cj` | generic | `jsonrpc4cj` [path]；`process4cj` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | x86_64 target bin path `${CANGJIE_STDX_PATH}` |
| `libs/sandbox4cj` | generic | `process4cj` [path] | — |
| `libs/skill_runtime` | hold/experimental | `yjson` [git:yjson pin]；`yjson_support` [path] | — |
| `libs/lsp4cj` | generic | `jsonrpc4cj` [path]；`process4cj` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | — |
| `libs/dap4cj` | generic | `process4cj` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | — |
| `agent_domain` | internal/packages | `process4cj` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | — |
| `agent_app_protocol` | internal/packages | `agent_domain` [path] | — |
| `agent_skills` | internal/packages | `agent_domain` [path]；`skill_runtime` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | — |
| `agent_runtime` | internal/packages | `agent_domain` [path]；`agent_skills` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | — |
| `agent_store` | internal/packages | `agent_domain` [path]；`agent_ports` [path]；`agent_runtime` [path]；`agent_skills` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | `link-option = "-lsqlite3"` |
| `agent_protocol` | internal/packages | `agent_domain` [path]；`jsonrpc4cj` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | — |
| `agent_ports` | internal/packages | `agent_domain` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | — |
| `agent_core` | internal/packages | `agent_domain` [path]；`agent_ports` [path]；`agent_runtime` [path]；`agent_skills` [path]；`tool_runtime` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | — |
| `tool_runtime` | internal/packages | `agent_domain` [path]；`agent_ports` [path]；`agent_runtime` [path]；`agent_skills` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | — |
| `persistence_runtime` | internal/packages | `agent_domain` [path]；`agent_ports` [path]；`agent_store` [path]；`model_adapters` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | — |
| `run_control` | internal/packages | `agent_core` [path]；`agent_domain` [path]；`agent_ports` [path] | — |
| `task_runtime` | internal/packages | `agent_domain` [path] | — |
| `agent_client` | internal/packages | `agent_core` [path]；`agent_domain` [path]；`run_control` [path] | — |
| `agent_cli` | internal/packages | `agent_domain` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | — |
| `agent_extensions` | internal/packages | `agent_domain` [path]；`agent_mcp` [path]；`agent_sdk` [path]；`tool_runtime` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | — |
| `agent_mcp` | internal/packages | `agent_domain` [path]；`agent_protocol` [path]；`mcp4cj` [path]；`process4cj` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | x86_64 target bin path `${CANGJIE_STDX_PATH}` |
| `model_adapters` | internal/packages | `agent_domain` [path]；`agent_ports` [path]；`llm4cj` [git:llm4cj pin]；`process4cj` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | x86_64 target bin path `${CANGJIE_STDX_PATH}` |
| `agent_embed` | internal/packages | `agent_core` [path]；`agent_domain` [path]；`agent_ports` [path]；`agent_runtime` [path]；`agent_skills` [path]；`tool_runtime` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | — |
| `agent_sdk` | ecosystem | `yjson` [git:yjson pin]；`yjson_support` [path] | — |
| `agent_extension_runtime` | internal/packages | `agent_sdk` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | — |
| `extensions/workspace_search_extension` | internal/packages | `agent_sdk` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | — |
| `extensions/workspace_write_extension` | internal/packages | `agent_sdk` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | — |
| `extensions/ast_extension` | internal/packages | `agent_sdk` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | — |
| `extensions/web_search_extension` | internal/packages | `agent_sdk` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | — |
| `axyndra_agent_testkit` | ecosystem | `agent_sdk` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | — |
| `agent_testkit` | internal/packages | `agent_domain` [path]；`agent_ports` [path]；`tool_runtime` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | — |
| `agent_product` | internal/packages | `agent_app_protocol` [path]；`agent_cli` [path]；`agent_client` [path]；`agent_core` [path]；`agent_domain` [path]；`agent_extension_runtime` [path]；`agent_extensions` [path]；`agent_mcp` [path]；`agent_ports` [path]；`agent_protocol` [path]；`agent_runtime` [path]；`agent_sdk` [path]；`agent_skills` [path]；`agent_store` [path]；`ast_extension` [path]；`dap4cj` [path]；`lsp4cj` [path]；`model_adapters` [path]；`persistence_runtime` [path]；`process4cj` [path]；`run_control` [path]；`sandbox4cj` [path]；`task_runtime` [path]；`tool_runtime` [path]；`web_search_extension` [path]；`workspace_search_extension` [path]；`workspace_write_extension` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | x86_64 target bin path `${CANGJIE_STDX_PATH}`；`link-option = "-lsqlite3"` |
| `agent_rpc` | internal/packages | `agent_cli` [path]；`agent_core` [path]；`agent_domain` [path]；`agent_product` [path]；`model_adapters` [path]；`tool_runtime` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | `link-option = "-lsqlite3"` |
| `agent_tui` | internal/packages | `agent_cli` [path]；`core` [vendor path]；`markdown` [vendor path] | — |
| `agent_app` | internal/packages | `agent_app_protocol` [path]；`agent_cli` [path]；`agent_client` [path]；`agent_core` [path]；`agent_domain` [path]；`agent_embed` [path]；`agent_mcp` [path]；`agent_product` [path]；`agent_rpc` [path]；`agent_tui` [path]；`core` [vendor path]；`model_adapters` [path]；`process4cj` [path]；`tool_runtime` [path]；`yjson` [git:yjson pin]；`yjson_support` [path] | `link-option = "-lsqlite3"` |

根 workspace 中有 31 个包直接声明 yjson。`agent_sdk` 的直接依赖只有 yjson 和 `yjson_support`，它不直接依赖 `agent_core`、`tool_runtime` 或产品 authority 包。静态依赖的 link option 不会自动传播到聚合 unittest executable，所以 `agent_store`、`agent_product`、`agent_rpc` 和 `agent_app` 的 SQLite 要求必须分别保留。

## workspace 外的包和测试闭包

### Vendored cjtui

`vendor/cj_tui` 不属于根 workspace。当前可读到三个 manifest：

- `vendor/cj_tui/packages/core` 无依赖。
- `vendor/cj_tui/packages/cj_markdown` 无依赖。
- `vendor/cj_tui/packages/markdown` 依赖同目录的 `core` 和 `cj_markdown`。

根 workspace 只有 `agent_tui` 和 `agent_app` 直接使用其中的 `core`；`agent_tui` 还使用 `markdown`。这些路径不是新的 stdx 依赖。

### 独立 sandbox experiment

`sandbox_runtime` 有自己的 manifest 和实现，不在根 `members`、`build-members` 或 `test-members` 中。它只通过 path 使用 `agent_domain` 和 `libs/sandbox4cj`，必须单独构建和验证。`subagent_runtime` 只有说明和迁移占位内容，不是当前可构建包。

### support_tests

当前可读到 64 个 `support_tests/*/cjpm.toml`。它们不是根 workspace member，但大量通过 path 递归使用生产包，并在自己的 manifest 中复制 yjson pin。需要把测试包的 path 目标解析到真实 manifest，不能把 support-test 的父目录或同名 sibling 项目当成产品依赖。

与 stdx 和这次候选迁移直接相关的测试入口如下：

| 生产消费者 | 直接使用或覆盖它的 support test | 触发的证据 |
| --- | --- | --- |
| `mcp4cj` | `support_tests/mcp_conformance_server`、`support_tests/native_provider_security_contract` | MCP conformance、原生 provider 安全和 HTTP/TLS 运行路径 |
| `agent_mcp` | `support_tests/mcp_contract`、`support_tests/mcp_extension_contract`、`support_tests/mcp_product_contract`、`support_tests/product_mcp_server_contract` | JSON-RPC、MCP-to-extension、产品组合和 server bridge |
| `process4cj` | `support_tests/sqlite_run_repository_contract`、`support_tests/thread_runtime_contract` | SQLite repository 和 thread runtime 的 process/cancellation 交互 |
| `model_adapters` | `support_tests/acp_lifecycle_contract`、`support_tests/artifact_contract`、`support_tests/direct_runtime_sandbox_contract`、`support_tests/gc_contract`、`support_tests/handoff_request_contract`、`support_tests/model_adapters_contract`、`support_tests/native_provider_security_contract`、`support_tests/product_continuation_contract`、`support_tests/product_contract`、`support_tests/product_prompt_contract`、`support_tests/product_rpc_contract`、`support_tests/product_thread_runtime_contract` | provider wire、凭据安全、retry/fallback、产品和 runtime 组合 |
| `agent_product` | 产品、MCP、GitHub、web search、sandbox、RPC、continuation、memory、prompt 等相关 contracts | composition root 对工具和 runtime 的组合证据 |

其中 6 个 support-test manifest 显式声明 `${CANGJIE_STDX_PATH}`：`checkpoint_compaction_contract`、`mcp_conformance_server`、`mcp_contract`、`mcp_extension_contract`、`native_provider_security_contract` 和 `prompt_memory_v3_contract`。只有两处 support-test 源码直接 import stdx：`support_tests/mcp_contract/src/main.cj` 和 `libs/mcp4cj/src/mcp_test.cj`；其他测试通过被测包的 target 和传递依赖获得构建要求。

两个需要递归解析的跨测试目录 path dependency 是 `support_tests/extension_runtime_contract` 和 `support_tests/sdk_fixture_extension_runner` 对 `../sdk_fixture_extension` 的引用。它们不是根 workspace package，也不能被文档清单遗漏。

## stdx 使用清单

### 源码 import

当前直接 import stdx 的生产源码只有 4 个文件，分布在 3 个直接源码消费者中：

| 源文件 | stdx API | 当前职责 |
| --- | --- | --- |
| `model_adapters/src/native_transport.cj` | `stdx.log.NoopLogger`、`stdx.net.http.*`、`stdx.net.tls.*` | `NativeProviderTransport` 的 provider HTTP、TLS、body 读取、取消、凭据阶段和错误映射 |
| `model_adapters/src/adapters.cj` | `stdx.crypto.crypto.*` | `SecureRetryJitterSource` 的安全随机 jitter |
| `libs/mcp4cj/src/http.cj` | `stdx.log.NoopLogger`、`stdx.net.http.*`、`stdx.net.tls.*` | `StreamableHttpMcpTransport` 的 request-scoped HTTP、SSE response、取消和 MCP header 处理 |
| `agent_product/src/product.cj` | `stdx.crypto.crypto.*` | `ProductIds` 的安全随机 ID 生成 |

直接 stdx import 的测试文件是 `libs/mcp4cj/src/mcp_test.cj` 和 `support_tests/mcp_contract/src/main.cj`。`agent_mcp/src/transport.cj` 中关于 stdio/transport 的说明字符串不是 import，不计入源码使用数。

对应 manifest 中明确设置 `${CANGJIE_STDX_PATH}` 的四个 workspace 包是 `libs/mcp4cj`、`agent_mcp`、`model_adapters` 和 `agent_product`。`libs/process4cj` 的 target path 是 `native`，它是 C shim 的本地物料，不应误计为 stdx path。

### 传递闭包

从三个直接 stdx 源码消费者沿 workspace manifest 的反向依赖闭包计算，受 stdx 影响的 8 个 workspace 包是：

```text
agent_app
agent_extensions
agent_mcp
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
- `scripts/prepare_native_deps.sh` 使用 `AXYNDRA_NATIVE_CC` 或 `PATH` 中的 `clang`，要求 LLVM/Clang >= 15，并以一次 C11/Linux capability probe 验证它，再把 `libs/process4cj/native/process4cj_native.c` 构建为 `libs/process4cj/native/libprocess4cj_native.so`。LLVM 15 是 reference/release baseline，而非唯一兼容版本。
- `scripts/package_candidate.sh` 先验证 SDK、完整 stdx、构建出的产品 executable 和 `patchelf`，再以 `ldd` 递归收集 process-native、SDK、tools 和 stdx 动态库，并检查最终诊断中没有 `not found`。
- `.github/workflows/pr-gate.yml` 以 LLVM 15 和 STS 1.1.3 作为 reference baseline；nightly gate 以匹配的 nightly SDK/stdx 和 LLVM 18 覆盖前向兼容，并把 SDK/stdx 检查放在构建测试之前。

`SecureRandom` 是 ID 和 retry jitter 的现有安全随机实现，与 stdx 到 Wirestack/sse4cj/yjson 的网络和 framing 迁移无关。迁移不能以删除安全随机为代价，也不在本轮提出随机数替代方案。

## 非 stdx 的系统要求

下表只列源码和脚本已经明确的消费者与触发条件。可选工具不是所有用户的安装前提；功能被启用时仍必须满足对应 executable 或库要求。

| 要求 | 消费者与触发功能 | 证据和范围 |
| --- | --- | --- |
| Linux x86_64 + glibc；支持 C11/Linux headers 的 Clang | `process4cj` 运行时；所有使用本地 process backend 的产品/合同 | `packaging/public-packages.toml` 将 `process4cj` 标为 `linux-x86_64`、`glibc`；其 C shim 使用 `AXYNDRA_NATIVE_CC` 或从 `PATH` 发现的 `clang` 构建。 |
| SQLite | `agent_store`、`agent_product`、`agent_rpc`、`agent_app` 以及相应聚合合同 | manifest 的 `link-option = "-lsqlite3"`；静态依赖的链接选项不自动传递。 |
| bubblewrap | `sandbox4cj` / `agent_product` 的 workspace sandbox | `libs/sandbox4cj/src/sandbox.cj` 默认使用 `/usr/bin/bwrap`，并验证 namespace 隔离；Linux 或 bubblewrap 不可用时返回 `Unsupported`，不退回裸执行。 |
| `timeout` | sandbox command 的 deadline wrapper | 默认 executable 为 `/usr/bin/timeout`；缺失时 sandbox availability 失败。 |
| `prlimit` | 仅当 `SandboxResourceLimits` 启用 address-space、file-size、open-files、processes 或 CPU limit | sandbox command 会在配置了 process limits 时加入 `/usr/bin/prlimit`；默认不因未配置资源上限而要求它。 |
| `curl` | `ProductWebSearchRuntime` 的 Brave、Tavily、SearXNG web search | `CurlWebSearchTransport` 解析 `/usr/bin/curl` 或 `/usr/local/bin/curl`，通过 `ProcessPort` 在只读 workspace、允许网络的 sandbox 中运行；对应 API key/URL 由 provider 配置决定。 |
| `git`、`gh` | GitHub tool 的 repo/file/PR/Actions 操作，及 worktree runtime | `ProductGithubRuntime` 默认解析 `/usr/bin/gh`、`/usr/local/bin/gh`、`/usr/bin/git`、`/usr/local/bin/git`；`gh api` 读文件，`gh pr` 做 checkout，`git push` 走显式批准的写操作。缺失只影响这些功能，不是基础 Agent loop 的所有用户前置。 |
| ripgrep (`rg`) | `grep` 和 `glob` 产品工具 | `agent_product/src/tools.cj` 以 `rg` argv 执行 workspace search/file listing，带只读 sandbox、超时和输出限制；产品未把它写成固定 `/usr/bin/rg`，由宿主 PATH 提供。 |
| `ast-grep` | `ast_grep` 和 `ast_edit` 工具 | `agent_product/src/ast_tools.cj` 固定调用 `/usr/bin/ast-grep`；AST edit 先生成 proposal，另有显式 resolve/reject 生命周期。 |
| `/bin/bash`、`/bin/sh`、`script` | `bash` 工具、clipboard staging、pty 分支 | shell 工具用 `/bin/bash --noprofile --norc -lc`；pty 分支使用 `script` 包装；clipboard 的可信 UI 边界使用 `/bin/sh` 和系统 clipboard 命令。它们受产品 process/sandbox policy，不等同于允许模型直接突破边界。 |
| Python、Bun、Ruby、Julia | `eval` 工具按语言选择 `/usr/bin/python3`、`/usr/bin/bun`、`/usr/bin/ruby`、`/usr/bin/julia` | 仅启用对应 eval 语言时需要；eval 请求仍进入 workspace read-write sandbox 和输出/超时限制。 |
| LSP server executable | `lsp` runtime | `agent_product/src/lsp_runtime.cj` 从 host 配置读取 executable、argv、文件类型、初始化选项和环境 binding，通过 `lsp4cj` 与长生命周期 managed process 通信；host 必须供应语言服务器。 |
| DAP executable | `debug` runtime | `agent_product/src/dap_runtime.cj` 从 host 配置读取 adapter executable 和 argv，通过 `dap4cj` 与 managed process 通信；host 必须供应 debug adapter。网络 attach 还必须由 adapter profile 显式允许。 |
| MCP stdio server executable | `mcp4cj` / `agent_mcp` 的 stdio transport | MCP 配置提供 executable、argv 和显式环境 binding；长生命周期子进程由 process4cj 管理。Streamable HTTP 则使用 stdx HTTP，不要求 MCP library 固定一个 server executable。 |
| SSH executable | 当前 `/ssh` 配置命令 | `agent_product/src/ssh_runtime.cj` 当前读写 project/user 的 `ssh.json`，源码没有把 `ssh` executable 接入这条配置管理路径。因此 SSH host 配置不是本轮可证明的 SSH 子进程运行要求；不要把它写成所有用户的安装前提。 |
| `patchelf`、`ldd`、可用 `awk`/`grep` | `scripts/package_candidate.sh` | `patchelf` 是 relocatable candidate 的硬要求；`ldd` 用于递归动态库闭包和最终缺库检查，`rp-awk`/`rp-grep` 不存在时脚本回退到系统 `awk`/`grep`。 |

Wirestack 若进入后续迁移，还需要其 manifest 声明的 resolver/TLS-provider native 物料以及 `-lstdc++ -lpthread -ldl -lm`。`python3 -B ../Wirestack/tools/build_native_dependencies.py --plan` 只输出 native 构建计划；输出 `READY` 不等于物料已经构建、SDK 兼容或 HTTPS 已验收。

## JSON 和取消边界

当前 JSON 不是首次替换 stdx JSON。Axyndra 的适配 seam 是 `libs/yjson_support/src/json_support.cj`：

- `AgentValue` 在 `agent_domain/src/domain.cj` 中就是 `JsonNode`，SDK 公开字段和参数也直接使用 JsonNode。
- `UnifiedJsonAccess` 把 yjson 的 `JsonKind.Js*` 归一化为 `Null/Boolean/Number/Text/List/Object`，集中提供 `field`、`put`、`add`、`stringify`、`parseUnifiedJson` 和 schema 错误投影。
- `items` 返回底层 array 的 live `ArrayList` alias；这是当前可观察行为，不能改成 snapshot 后仍声称无损替换，也不能要求 yjson 暴露私有 backing storage。
- yjson 的公开容器访问应使用 `JsonArray.size/get/add` 和 `JsonObject.size/nameAt/valueAt/put`。不能直接调用包内的 `values()`/`entries()`。
- schema 适配由上层把 yjson_algorithms 的 violation path/keyword 映射回现有合同，不能要求通用 JSON 库理解 Axyndra 的业务字段。

`agent_domain/src/v3_control.cj` 使用 `process4cj as process` 参与 cancellation/runtime 类型适配；这与 `agent_domain` 没有 stdx import 是两个不同层次的事实。架构文档必须同时保留这两个事实，不能为了画出纯领域图而反向修改 manifest。

## 静态验证结果与限制

本轮文档审计的只读门禁如下，不调用会生成 SDK cache、native shim 或 build directory 的 `scripts/pinned_cangjie`：

```sh
python3 -B scripts/dependency_pin_gate.py
python3 -B scripts/check_library_boundaries.py
python3 -B scripts/docs_gate.py
```

基线结果为：

- `dependency pin gate passed (33 llm4cj locks, commit=62e6c57227630f2ccbc0f48fecfdf36a896e7e6d)`；
- `reusable library boundaries passed (8 libraries)`；
- 新增文档后再次运行 docs gate，以当前 Markdown 文件数和 38 个 workspace 包为准，不把旧的 `10 markdown files` 计数写成永久断言。

候选 Wirestack 目录存在时，可以只运行计划器：

```sh
python3 -B ../Wirestack/tools/build_native_dependencies.py --plan
```

本次审计记录的计划器输出是 `{"platform": "linux-x86_64-glibc", "status": "READY", "steps": ["tls-provider", "resolver"]}`。它只证明计划器识别出两类 native 输入。

一次性 TOML 解析核对得到：38 个 workspace 包、31 个直接声明 yjson 的成员，以及以下 stdx 传递闭包：

```text
agent_app
agent_extensions
agent_mcp
agent_product
agent_rpc
libs/mcp4cj
model_adapters
persistence_runtime
```

这些静态结果不证明 SDK/stdx/native 组合可编译，不证明 Wirestack/sse4cj 的运行语义等价，也不证明真实 provider、MCP server、PTY、打包产物或目标平台已经通过。运行合同、输入、预期结果和现有测试入口见 [stdx 迁移执行规格](stdx-migration.md)。
