# 插件 HTTP 凭据与公开请求头

HTTP 认证由 `plugins/services.json` 中的宿主授权配置注入。插件只持有
`credential_refs`；凭据值不进入插件配置、纯准备结果、Operation、Receipt 或 IPC。
秘密文件位于 settings 下的 `credentials/`，也可显式引用一个宿主环境变量。
配置读取与纯准备不解析秘密；实际准入后的 HTTP 执行才解析。

原先的 MCP `bearer_token_env: MCP_TOKEN` 若变量保存的是裸 token，应显式转换为：

```json
{
  "ref": "mcp-token",
  "source": {"environment": "MCP_TOKEN"},
  "injection": {"header": "Authorization", "prefix": "Bearer "}
}
```

把该 ref 同时列入匹配 URL/方法的 operator request grant 与 MCP 插件
`http.credential_refs`。不能把环境变量值复制到插件配置。省略 `prefix` 时保留原有
原样注入行为；已经含 `Bearer ` 的来源应省略前缀。宿主不猜测认证协议。
`prefix` 最多 128 字节可见 ASCII，只支持 header injection，不支持模板或 JSON body
injection。拼接后 header value 最多 8 KiB。输出过滤同时覆盖裸秘密与带前缀的值。

旧自定义环境变量 header 认证通过另一条 `ref`、显式 source 和目标 header 映射；
不把秘密放入下面的公开 `headers`。凭据不能覆盖请求中已有的同名 header。
来源轮换不改变包授权；配置变更使旧冻结授权失效，必须重新启动受控服务。

独立 MCP 插件的 `configuration.http` 另外接受可选公开字段：

```json
{
  "url": "https://mcp.example.test/mcp",
  "credential_refs": ["mcp-token"],
  "max_response_bytes": 65536,
  "prefer_sse": true,
  "origin": "https://client.example.test",
  "headers": {"X-Deployment": "public-name"}
}
```

Origin 与业务 header 的生成属于 MCP 插件；宿主仍执行通用 HTTP 校验与授权。
公开 headers 最多 16 项，拒绝大小写重复、控制字符、认证/连接/代理和 MCP 协议保留
字段。Origin 使用 MCP library 的安全 origin 校验。它们进入冻结请求，审批后不能
通过更新配置重定向。旧配置不含这两个字段时保持原行为。

旧 `mcpServers` 配置不会自动成为新包授权。包摘要、namespace、目标 URL/方法、
私网地址和 credential refs 必须显式配置；旧配置与历史文件保留，不能用不完整的
自动转换覆盖。代理配置和不受支持的旧字段需要显式诊断，不能静默丢弃。
