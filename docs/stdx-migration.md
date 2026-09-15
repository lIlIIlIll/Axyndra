# stdx 迁移执行规格

> 尚未切换。当前源码与候选 API 的形状匹配，不是运行验收通过。

本规格定义把 Axyndra 当前 stdx HTTP、SSE 和 JSON 使用迁移到 Wirestack、sse4cj 和 yjson 时的适配归属、迁移顺序和准入合同。依赖、pin、workspace 闭包、宿主 executable 和 SDK/native 前置见 [依赖与 stdx 审计](dependencies.md)。

## 前置条件

迁移开始前必须同时满足以下条件：

- 选定并记录一组 Cangjie SDK、stdx 和 native 物料。`scripts/check_sdk.sh` 的最低版本检查、`scripts/sdk_paths.sh` 对 `libstdx.net.http.so` 的检查、`scripts/prepare_native_deps.sh` 对 C11/Linux compiler capability 的检查都保持不变；只有 release gate 启用精确版本复现。
- yjson 使用 commit `92858f75aedc3dd6f7322789117854514549e62c`，llm4cj 使用 commit `62e6c57227630f2ccbc0f48fecfdf36a896e7e6d`；所有受影响 lockfile 同步更新并经过现有 pin gate。相邻 `../yjson`、`../llm4cj`、`../Wirestack` 和 `../sse4cj` 工作树只能作为源码对照，不能直接写进 Axyndra manifest。
- yjson schema 的可复现来源和兼容的 yjson/macros/llm4cj 闭包必须确认。当前 `yjson_algorithms` 只有相邻 `../yjson/packages/yjson_algorithms` 源码证据，不能用开发机 path 作为 CI 依赖。
- HTTP、SSE、JSON 的行为合同先有可执行 fixture 或现有合同入口，再提交适配。候选库的 API 可见不等于 TLS、取消、EOF、预算、错误分类或 native 物料已经验收。
- 迁移只沿依赖方向向下调用。Wirestack、sse4cj 和 yjson 不依赖 Axyndra 的 Agent DTO、provider 名称、MCP 产品错误码或产品 schema。

## 适配归属

### `model_adapters` 拥有 provider 语义

保留当前产品 seam，不把 Wirestack API 向上泄漏：

```text
ProviderTransport.post(
    provider: ProviderSpec,
    payload: String,
    streaming: Bool,
    requestId: String,
    chunks: (String) -> Unit
): domain.Result<String>

ProviderTransport.cancel(requestId: String): domain.Result<Unit>
```

`model_adapters` 负责把 Agent request/response 投影到 llm4cj wire DTO，解析凭据，校验 HTTPS/loopback URL，绑定 request ID，维护总 deadline 和取消，控制 64 MiB response 上限，脱敏错误和流片段，并决定 retry/fallback。Wirestack 只提供通用 HTTP/TLS/response body/cancellation primitive，不认识 `ProviderSpec`、Agent error code 或 provider 名称。

### `libs/mcp4cj` 和 `agent_mcp` 分层

`libs/mcp4cj` 相对 HTTP/SSE 库是上层。它拥有 MCP header、JSON-RPC 关联、notification/subscription、request-scope 生命周期、MCP protocol error 和现有 `/mcp` wire 形状。`agent_mcp` 继续拥有产品配置、secret environment binding、server lifecycle 和 `AgentError` 映射。

MCP server/client 不为了复用 provider adapter 而共用产品错误模型；`libs/*` 不反向依赖 Agent 包。stdio 继续是长生命周期 process4cj 子进程，Streamable HTTP 继续是 stdx HTTP 的 MCP transport，直到 Wirestack 通过下面的 HTTP server/client 合同。

### `llm4cj` 拥有 LLM stream 语义

llm4cj 相对 sse4cj 是上层。SSE framing 接入由 llm4cj 自己吸收，provider terminal、tool-call、usage、reasoning、error context、stream budget 和 protocol dialect 保留在 llm4cj。Axyndra 继续消费 `LlmWireStreamDecoder.push` 与 `finish`，不增加“解码 SSE → 重编码 SSE → 再交给 llm4cj”的管线，也不复制 llm4cj 的 provider state machine。

### `yjson_support` 拥有 Axyndra JSON 适配

yjson 是通用 JSON/parser/schema library。Axyndra 的业务字段、`AgentValue`、SDK public fields、schema path/keyword 投影和对象/数组可观察语义继续由 `libs/yjson_support` 与调用方拥有。yjson 不引入 Agent 类型，也不为上层暴露私有 backing storage。

## 候选能力对照

状态只使用以下含义：

- **上层可适配（仅源码证据）**：候选公开接口能表达现有 seam，但尚未做运行验收。
- **通用能力前置**：候选包或 native/toolchain 缺少独立通用能力，需先解决，不能由 Axyndra 私有 workaround 掩盖。
- **行为差异阻塞**：当前语义不同；消除差异或批准上层合同变更前不得切换。
- **未验证**：已有源码线索，但缺少指定版本、运行结果或物料证据。

### HTTP

| 当前调用 | 候选公开 interface | 适配与所有者 | 准入状态和证据 | 源码证据 |
| --- | --- | --- | --- | --- |
| provider request/client/headers，`NativeProviderTransport` | `HttpClient.builder()`；`HttpRequest.post(url, RequestBody.string(body))`；`HttpHeaders.builder().add(name, value).build()` | `model_adapters` 将 provider headers 转为 immutable `HttpHeaders`，保留认证头由凭据边界生成。`Int64` HTTP status 转为产品需要的类型；MCP 的 `UInt16` 转换留在 mcp4cj。 | 上层可适配（仅源码证据）。Wirestack `HttpRequest`、`RequestBody`、`HttpHeaders` 已公开；未验证 SDK/native 组合。 | 当前：`model_adapters/src/native_transport.cj` `NativeProviderTransport`；候选：`../Wirestack/src/http/client.cj` `HttpClientBuilder`、`../Wirestack/src/http_message.cj` `HttpRequest`、`../Wirestack/src/http_model.cj` `HttpHeaders`。 |
| response body | `HttpResponse.status: Int64`、`headers`、`body: ResponseBody`；`ResponseBody.contentLength: ?Int64`、`read(destination)`、`close()` | `model_adapters` 保留 body 累计 64 MiB 上限和已经交付的流证据。`contentLength = None` 表示未知长度，不能当作零；读失败和关闭仍映射为 transport/timeout。mcp4cj 把 HTTP body 生命周期封装在现有 MCP response 处理中。 | 上层可适配（仅源码证据）。Wirestack `ResponseBody` 是单所有者、可读/close 的 response body；未知长度、读取错误和连接复用未运行验证。 | 当前：`model_adapters/src/native_transport.cj` body read；候选：`../Wirestack/src/http_message.cj` `ResponseBody`。 |
| timeout/cancel | `HttpClient.sendControlled(request, HttpCancellationHandles, context: OperationContext, trailer: HttpTrailer)`；`OperationContext.shortenDeadline` / `withEarlierDeadline` | request ID registry 继续持有 request/connection/stream cancellation handles。正时限转换为一个绝对 operation deadline，覆盖 DNS、connect、TLS、headers、body 和回调；凭据解析阶段仍可在创建 client 前取消。`timeoutMillis = 0` 使用无 deadline 的 context，不调用只接受正值的 `requestTimeout`。 | 上层可适配（仅源码证据），运行延迟未验证。当前 stdx transport 每请求一个 client；适配必须保留独立请求之间的隔离、重复 cancel 幂等和结束后 request ID 复用。 | 当前：`model_adapters/src/native_transport.cj`、`model_adapters/src/adapters.cj`；候选：`../Wirestack/src/http/client.cj` `sendControlled`、`../Wirestack/src/operation_context.cj` `OperationContext`。 |
| TLS/trust | 默认 `HttpClient` 惰性使用 `systemDefaultAlpn()` / `systemDefault()`；显式 custom roots 或 mTLS 使用 `HttpClientTlsConfig` | 不复制系统 CA 发现逻辑，也不新增下层 system-trust 入口。`model_adapters` 继续拥有 HTTPS/loopback URL policy、凭据和错误脱敏；只有显式 custom roots/mTLS 时才配置下层 TLS。 | 上层可适配（仅源码证据）；真实信任链和 hostname 校验未验证。Wirestack `TrustPolicy.system()` 已存在，不能把“新增系统 CA API”列成必要底层任务。 | 当前：`model_adapters/src/native_transport.cj`；候选：`../Wirestack/src/http/client.cj`、`../Wirestack/src/trust.cj` `TrustPolicy.system`、`../Wirestack/src/http/tls.cj` `HttpClientTlsConfig`。 |
| redirect | `HttpRedirectPolicy(maximumRedirects: 0)` | 当前 stdx `autoRedirect(false)` 的目标是把原始 3xx、Location 和 body 原样交给上层。Wirestack 在带 Location 的 3xx 且 `maximumRedirects = 0` 时抛 `TooManyRedirects`，并由 `HttpClient.sendInternal` 关闭原 response；它不是无损等价物。需要通用的“不访问 Location、保留原 response”策略，或由上层取得等价实现后才能切换。 | 行为差异阻塞。重定向 fixture 必须确认原 status/body 被 provider/MCP 收到，Location 目标请求次数为 0。 | 当前：`model_adapters/src/native_transport.cj`；候选：`../Wirestack/src/http/redirect.cj` `HttpRedirectPolicy`、`../Wirestack/src/http/client.cj` `sendInternal`。 |
| retry | `HttpRetryPolicy(maximumAttempts: 1)`；默认 `maximumAttempts = 2` | Wirestack 的传输尝试不能与 `model_adapters` 的 retry/fallback loop 叠加。默认使用一次下层尝试，provider/MCP 上层保留错误分类、Retry-After、部分 stream 后禁止 retry/fallback 等语义。 | 上层可适配（仅源码证据）；必须运行确认重复尝试没有发生。 | 当前：`model_adapters/src/adapters.cj` retry/fallback；候选：`../Wirestack/src/http/retry.cj` `HttpRetryPolicy`。 |
| MCP server/streaming | `HttpServer.builder().listen(SocketEndpoint).handler(HttpServerHandler).build()`；handler `handle(HttpServerRequest, OperationContext): HttpServerResponse`；`HttpServer.shutdown(context:)` 和 `close()` | `mcp4cj` 把当前 `InputStream & Resource` SSE response body 适配为 `HttpBodyStream`，实现 `contentLength/read/close` 后构造 `ResponseBody`。`/mcp` route、POST-only、Origin/Bearer、Mcp-* headers、JSON-RPC response/notification/subscription 仍由 mcp4cj 拥有。 | 上层可适配（仅源码证据），server graceful shutdown、body backpressure 和 native 输入未验证。不引入当前产品没有的 GET/DELETE session protocol。 | 当前：`libs/mcp4cj/src/http.cj`；候选：`../Wirestack/src/http/server.cj` `HttpServer`、`../Wirestack/src/http_body.cj` `HttpBodyStream`、`../Wirestack/src/http_message.cj` `ResponseBody`。 |

Wirestack 的 `HttpClientBuilder` 还会选择系统 resolver，并要求 resolver/TLS-provider native 物料。其 manifest 需要 `-lstdc++ -lpthread -ldl -lm`。`../Wirestack/tools/build_native_dependencies.py --plan` 的 `READY` 只表示计划器识别出 `tls-provider` 和 `resolver` 两项，不表示物料已经生成或 SDK 兼容。

### SSE

| 当前调用 | 候选公开 interface | 适配与所有者 | 准入状态和证据 | 源码证据 |
| --- | --- | --- | --- | --- |
| provider 的 llm stream | llm4cj `LlmWireStreamDecoder.push(chunk: String/Array<Byte>)`、`finish()`、`cancel()` | `model_adapters` 保持当前 provider transport seam，llm4cj 负责从事件到 text/reasoning/tool-call/usage/terminal 的状态机。 | 上层可适配（仅源码证据）。已读源码显示 llm4cj 自己持有 `SseDecoder` 和 semantic stream decoder；锁定 commit 与候选工作树的 JSON/SSE API 仍须一起核对。 | 当前：`model_adapters/src/native_transport.cj`；候选：`../llm4cj/src/stream.cj` `LlmWireStreamDecoder`。 |
| 通用 framing | sse4cj `SseDecoder.feed(bytes, sink)`、`finish(sink)`；`SseDecodeSink.onEvent(SseEvent)`、`onRetryChanged`、`onLastEventIdChanged` | sse4cj 只产生通用 `eventType/data/lastEventId` 事件。mcp4cj 把它们转成 JSON-RPC envelope；llm4cj 自己把它们交给 provider codec。 | 上层可适配（仅源码证据），但只使用 decoder 仍带 stdx HTTP/server 的包级构建依赖。若目标是彻底消除 sse4cj 的 stdx 要求，必须先完成包级解耦这一通用能力。 | 当前：`libs/mcp4cj/src/http.cj`；候选：`../sse4cj/src/decoder.cj` `SseDecoder`、`../sse4cj/src/wire_models.cj` `SseEvent`。 |
| BOM、分块、CRLF、retry | `feed` 可在任意 byte boundary 分块；`finish` 处理 pending CR 和 BOM | 上层需要覆盖 BOM 在独立 chunk、UTF-8 中文在独立 chunk、CRLF 在独立 chunk、`retry` 与空格处理。事件映射预期 `data` 字段以单个换行拼接，缺省 event type 为 `message`。 | 未验证。候选 decoder 的非法 UTF-8 会替换，锁定 llm4cj 当前合同对非法 UTF-8 返回 `llm.sse_utf8_invalid`；不能只看正常 ASCII fixture。 | 当前：`libs/mcp4cj/src/http.cj`、`model_adapters/src/native_transport.cj`；候选：`../sse4cj/src/decoder.cj`、`../llm4cj/src/transport.cj`。 |
| EOF 未完成 event | sse4cj `finish` 会丢弃没有空行结束的 incomplete block；当前 mcp4cj reader 会处理 EOF 时已累积的 data | MCP 的 EOF 行为是上层协议合同，不能由通用 decoder 默认值静默改变。llm4cj 的 terminal missing/error context 也必须保留。 | 行为差异阻塞。必须分别记录 sse4cj 替换/丢弃和 llm4cj/MCP 当前拒绝或完成行为。 | 当前：`libs/mcp4cj/src/http.cj`；候选：`../sse4cj/src/decoder.cj` `finish`、`../llm4cj/src/stream.cj` `finish`。 |
| 预算 | llm4cj SSE defaults：line 1 MiB、event 8 MiB、buffer 16 MiB、每 push 1024 events、每 push output 16 MiB；sse4cj defaults：line/field 64 KiB、data 1 MiB、event 2 MiB、buffer 4 MiB | 不照搬候选较小 default 以悄悄缩小产品输入范围。llm4cj 保留 semantic、text、reasoning、tool argument、retained state 和 event budgets；mcp4cj 保留 MCP framing/request limits。 | 通用能力前置 + 未验证。必须明确每个限制是当前字节计量、parser retention 还是消费端 semantic/output budget。 | 当前：`model_adapters/src/native_transport.cj`、`libs/mcp4cj/src/http.cj`；候选：`../llm4cj/src/stream.cj`、`../llm4cj/src/transport.cj`、`../sse4cj/src/decoder.cj`。 |

### JSON

这是已接入 yjson 后的 API/包拓扑整理，不是首次把 stdx JSON 换成 yjson。Axyndra seam 固定在 `libs/yjson_support/src/json_support.cj`，迁移不得绕过 SDK/public testkit 的冻结消费者和 API baseline。

| 当前用法 | 候选公开 API | 适配与所有者 | 准入状态和证据 | 源码证据 |
| --- | --- | --- | --- | --- |
| `JsonKind.Js*`、`string`/`bool`/`numberText` | yjson `JsonKind.Null/Boolean/Number/String/Array/Object`；`JsonValueView.asString/asBool/asNumberText`；`JsonNode` 静态构造器 | `yjson_support` 继续提供 `UnifiedJsonKind`、`text`、`boolean`、`number`，业务代码继续使用 `AgentValue = JsonNode`。 | 上层可适配（仅源码证据）。锁定 yjson 和相邻候选 yjson 的 enum spelling、构造器和 accessors 必须按同一 pin 编译。 | 当前：`libs/yjson_support/src/json_support.cj`；候选：`../yjson/src/lib_json_value.cj` `JsonKind`、`JsonValueView`、`JsonNode`。 |
| `YJson.parse` + `JsonReadConfig` | `JsonNode.parse(text, config: JsonReadOptions)`，也有 bytes 入口 | `parseUnifiedJson` 把旧 maxBytes 映射到 `maxInputBytes`、`maxStringBytes`、`maxBufferedValueBytes`，保留 Reject duplicate、Preserve number literal 和 maxDepth；不保留旧配置 alias。`JsonNode.parse(bytes)` 只在 body/stream 证据需要时使用。 | 行为差异阻塞 + 未验证。必须证明限制边界没有额外拒绝或放宽，并同步锁定仍使用旧 API 的 llm4cj consumer。 | 当前：`libs/yjson_support/src/json_support.cj`；候选：`../yjson/src/lib_json_value.cj` `JsonReadOptions.parse`。 |
| `YJson.stringify/value/nullValue` 与旧构造器 | `JsonNode.toJson()`；`JsonNode.boolean/string/number/array/object`；`JsonNode.nullValue` | 数字使用文本入口，禁止经 Float64 往返；对象字段顺序由上层保留；`jsonObject` 在 Axyndra seam 拒绝 duplicate key。 | 上层可适配（仅源码证据）；number literal、escape、order 和 duplicate key 需要运行合同。 | 当前：`libs/yjson_support/src/json_support.cj`；候选：`../yjson/src/lib_json_value.cj` `JsonNode` constructors/toJson。 |
| 对象/数组内部容器 | 公开 `JsonArray.size/get/add`；`JsonObject.size/nameAt/valueAt/put` | 不调用 yjson 包内 `values()`/`entries()`，也不要求 yjson 暴露 backing storage。 | 行为差异阻塞。当前 `UnifiedJsonAccess.items` 返回 live `ArrayList<JsonNode>` alias；改成 snapshot 是上层可观察契约变更，不属于无损切换。 | 当前：`libs/yjson_support/src/json_support.cj`；候选：`../yjson/src/lib_json_value.cj` `JsonArray`/`JsonObject`。 |
| schema | `yjson_algorithms.JsonSchema.fromValue(JsonValueView)`；`validate(JsonValueView): JsonSchemaResult`；`JsonSchemaViolation.instancePath/schemaPath/code/message` | `yjson_support.validateUnifiedJsonSchema` 把 violation 映射回既有 `path/keyword/message`。保留 required 的 `$` 与类型错误的 `$["name"]` 语义，不要求通用库直接输出产品 JSONPath。 | 未验证。`yjson_algorithms` 独立可复现来源和 pin 尚未确认，不能用相邻 path 直接通过 CI。 | 当前：`libs/yjson_support/src/json_support.cj`；候选：`../yjson/packages/yjson_algorithms/src/lib_json_schema.cj` `JsonSchema`/`JsonSchemaViolation`。 |

JSON 线有三个硬门槛：

1. `items` 的 live alias 是现有行为。没有上层合同决定前，不改为 snapshot，也不要求 yjson 打开私有 storage。
2. `yjson_algorithms` 的独立来源/pin 未确认。不能删除 schema validation 以换取可编译，也不能把开发机 sibling path 写入 product manifest。
3. 新 yjson 必须与兼容的 llm4cj 修订一起核对。相邻 llm4cj 使用 `JsonNode.parse`/`JsonReadOptions` 的映射可参考，但 `branch = "main"` 不满足 Axyndra 的 pin 规则；macros 的 path/test-dependency 闭包另行审计。

JSON-RPC 数字 ID 还必须保留现有合同：`1e3` 和 `1000` 的编码文本不同但关联判等；`9007199254740992` 与 `9007199254740993` 不因 Float64 舍入而相等。复用 `libs/jsonrpc4cj/src/jsonrpc_test.cj`，不要用浮点中间值。

## 迁移顺序

1. **候选来源、native 和 toolchain 证据**：锁定候选 revision；确认 Wirestack resolver/TLS-provider 输入、Cangjie/stdx 组合、`process4cj` C shim 和发布动态库闭包。没有这些物料时停在未验证，不修改产品依赖。
2. **provider HTTP**：在 `model_adapters` 适配 Wirestack client/body/cancellation/TLS，并先通过 provider timeout/cancel/security/redirect 合同。Retry/fallback 仍属于 provider。
3. **MCP HTTP**：在 `libs/mcp4cj` 适配 client/server body 与 graceful shutdown；`agent_mcp` 只更新产品配置和错误映射。provider HTTP 和 MCP HTTP 的实现互不依赖，可以分别准入。
4. **SSE 复用**：先解决 sse4cj package-level stdx dependency 和非法 UTF-8/EOF 行为差异，再让 llm4cj 吸收 framing；不在 Axyndra 增加重复编解码。
5. **JSON 独立迁移线**：先确认 schema 来源、live alias、number/duplicate/depth/size 语义，再选择相容 yjson/llm4cj pins，统一受影响 package lock。JSON 不因 HTTP/SSE 替换而同步升级。
6. **最终 stdx 闭包复核**：重算源码 import、8 个 workspace 传递包、support-test target、SDK path、native/link 和 candidate package 动态库。`SecureRandom` 仍由 stdx crypto 提供，不能作为网络库迁移的减项。

## 行为验收合同

本节是后续迁移的准入输入与结果，不是当前通过结果。本轮不运行这些 runtime tests，也不新建测试。

### 1. Provider partial timeout

在 `support_tests/model_adapters_contract` 的 provider fixture 中发送 JSON `{"case":"partial-timeout"}`，设置 `timeoutMillis=100`，先交付部分 SSE，再让 response 超时。消费端必须得到 `AgentErrorKind.Timeout`、`model.timeout` 和 `partial_stream=true`；已经交付部分 stream 时禁止 retry/fallback。另用持续产生数据但超过总时限的 `partial-active-timeout` 覆盖“有进度不等于延长总 deadline”。

### 2. Active cancellation

在 `support_tests/model_adapters_contract` 启动活跃 `stalled-cancel` 请求，设置 `timeoutMillis=0`。调用 cancel 必须低于既有 loopback 750 ms threshold，并在既有 1000 ms threshold 内结束；重复 cancel 幂等，结束后同一 request ID 可复用，独立请求不受影响。还要覆盖凭据解析阶段尚未创建 HTTP client 时的取消。

### 3. TLS trust and hostname

通过 `support_tests/native_provider_security_contract/check.sh` 的 loopback TLS fixture 使用无可信根的自签名证书，连接必须拒绝，不能关闭校验。增加一个“根证书已可信但 hostname 不匹配”的输入，结果也必须拒绝；现有自签名 fixture 不能单独证明 hostname 校验。响应、错误、callback 失败和取消路径均不得泄露认证信息。

### 4. SSE framing and budgets

对 sse4cj decoder 和 llm4cj consumer 输入以下逻辑内容：真实 BOM、CRLF、中文 UTF-8 和 retry 字段：

```text
\uFEFF:keepalive\r\nid: 7\r\nretry: 12\r\ndata: 中\r\ndata: x\r\n\r\n
```

这里 `\uFEFF` 表示真实 BOM，`\r\n` 表示真实 CRLF，不是把反斜杠字符送入 parser。分别整块 feed，并在 BOM、中文 UTF-8 和 CRLF 中间分块 feed。事件结果必须是 `data = 中\nx`、`eventType = message`、`lastEventId = 7`；sse4cj 的 retryMillis 和 llm4cj 事件的 retryMillis 均为 `Some(12)`。

再输入 `data: ` + byte `0xFF` + `\n\n`，以及没有末尾空行的 `data: x` 后调用 finish，分别记录两端的非法 UTF-8 拒绝/替换和 EOF 行为。LLM 集成还必须保留 terminal、usage、tool-call 和流预算；framing 相似不能替代语义集成。入口为 `support_tests/model_adapters_contract`、`support_tests/mcp_contract` 和 `libs/mcp4cj` 的现有测试。

### 5. MCP notification/response correlation

在 `support_tests/mcp_contract` 的 MCP SSE fixture 中先发送 notification，再发送不匹配 id response，最后发送匹配 id response。notification 必须先交付，只有匹配 response 才结束 request；subscription 的关闭和 cancel 行为保持现有合同。EOF 缺少匹配 response 时返回 `mcp.http_sse_response_missing`。另外记录当前 MCP reader 接受 EOF 累积 data 与候选 decoder 丢弃未结束 block 的差异。

### 6. Redirect preservation

建立返回 `302`、`Location` 和可识别 body 的 redirect fixture。上层必须收到原 status/body，Location target 请求次数为 0。候选 `HttpRedirectPolicy(maximumRedirects: 0)` 当前会抛异常并关闭原 response，因此此合同在实现前属于行为差异阻塞，不能标为已通过。覆盖 provider 和 MCP 需要的策略配置。

### 7. JSON parsing, limits, and schema

在 `libs/yjson_support` 及其现有 consumer 中验证：

- `{"n":1e0,"ok":true}` 保留 number text `1e0`；
- `{"z":1,"a":2,"m":3}` 保持字段顺序；
- duplicate key `{"a":1,"a":2}` 被拒绝；
- `{"long":true}` 配 `maxBytes=4` 被拒绝；
- `[[[0]]]` 配 `maxDepth=2` 被拒绝；
- schema 验证 `{}` 和 `{"name":1}` 分别保留 `$`/required 与 `$["name"]`/type；
- 保存 `[1,2]` 的 `items` 后调用 `add(3)`，明确记录 live alias 差异。

执行入口可沿用 `scripts/product_unit_gate.py` 选择的 workspace member 路径，但本轮不运行 Cangjie runtime test。

### 8. JSON-RPC numeric IDs

复用 `libs/jsonrpc4cj/src/jsonrpc_test.cj` 的实际合同：`1e3` 与 `1000` 保留各自编码文本但关联判等；`9007199254740992` 与 `9007199254740993` 不相等。SDK 和 public testkit 的冻结消费者、`compat` API baseline 和 extension contract 不得因 JSON 整理被绕过或重写。

## 运行证据入口

后续聚焦合同按现有 implementation gate 方式运行。先设置满足 `scripts/check_sdk.sh` 最低版本且带匹配 runtime/stdx 的 `AXYNDRA_SDK_ROOT`；release gate 继续要求固定的可复现版本。

在 `support_tests/model_adapters_contract` 或 `support_tests/mcp_contract` 中：

```sh
../../scripts/pinned_cangjie cjpm build
../../scripts/pinned_cangjie target/release/bin/main
```

原生 provider 安全合同的入口是 `bash support_tests/native_provider_security_contract/check.sh`，需要 Python 3、OpenSSL CLI、Cangjie SDK 和匹配的 stdx。JSON 线可使用：

```sh
scripts/pinned_cangjie cjpm test -m libs/yjson_support --no-color
scripts/pinned_cangjie cjpm test -m libs/jsonrpc4cj --no-color
python3 -B scripts/check_sdk_compatibility.py
```

这些命令要求 SDK/stdx/native 环境已经对齐；source/API 匹配、静态 gate 或候选 plan 输出都不能替代它们。
