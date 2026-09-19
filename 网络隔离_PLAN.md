# 统一执行策略、域名网络隔离与恢复语义

## Context

用户要求根据执行失败、联网和恢复链路的讨论优化 Axyndra 架构与实现。已确认三个产品决定：

1. 普通命令默认禁网，联网必须按需授权。`bash` 与 `hub` 使用相同的权限语义。
2. 本次包含真实域名级出站隔离，不接受仅增加 `hosts` 参数或代理环境变量。
3. 不考虑兼容性。直接调整接口、工具 schema、配置与存储格式，不保留旧别名、双写、兼容解码或第二套执行路径。

### 源码结论

- `agent_product` 已直接使用 `sandbox4cj`。一次性进程、长期进程与 MCP stdio 有三处生产 `WorkspaceSandboxPolicy` 构造。`hub` 子进程没有绕过文件和进程沙箱。外部 broker 自身属于受信控制进程。
- `NetworkIsolationMode.Allowed` 当前不建立 network namespace，因而开放宿主网络。`bash` 没有联网参数，`hub` 只有 Boolean。GitHub、web search 和 isolated extension 的显式联网调用也降成 Boolean。
- 沙箱构造稀疏 `/etc`，挂载 DNS 文件但不挂载 CA。`curl -k` 成功不能证明 TLS 正常。修复应提供可信 CA，而不是关闭证书验证。
- `NormalizedOperationPlan` 已绑定参数、能力集合、资源、cwd、环境、审批、effect 和 retry。持久化 shell 也已有 `sandboxPlanProfile`。不再增加平行 `ExecutionPolicy`、授权散列或 shell profile 散列。
- 当前 session grant 按单个 `metadata.grantScope` 匹配。默认 scope 不包含附加网络能力，不能安全承载“离线 shell 授权”和“联网 shell 授权”的区别。
- `ToolPipeline` 写 `tool_operation_intents` 与 intent receipts，Core 又写 canonical `operations` 与 `operation_receipts`。两套记录使错误与恢复责任分散。canonical store 已保存完整 normalized plan，并有审批、handoff 和 program sub-operation 接口。
- `commitCanonicalToolAttempt` 忽略 `RuntimeOperationResolution.resolution`。Unknown 可能已持久化，但 Core 仍用原始 Internal 错误把 Run 结算成 Failed。
- Thread 结算会清空活动标记。registry 的热路径、冷路径和删除检查主要依赖活动标记，未把已结算但未对账的 Unknown 操作作为门禁。当前 recovery planner 也漏掉无活动 Turn 或已有 Unknown ToolResult 的情况。
- `ApplicationSession` 的 start、resume、decide、handoff、计划纠正和 goal continuation 错误处理不一致。仅补 `pendingRecovery` 不能修复持久化门禁。
- `LocalWorkspace.writeFile` 把 staging、publish 和后处理异常压成 `Internal/workspace.write`。缺失父目录是可构造的前置失败，但现有会话材料不足以证明它就是此前那次失败的根因。
- `read` 已有 `InternalUriRouter`，但默认没有 HTTP(S) handler。RPC 注册的 URI 当前缺少完整的能力与 effect 声明，不能直接注册 `https` 后沿用 WorkspaceRead。

### 完成后的边界

```text
Tool Call / 已批准的服务配置 / 显式用户控制命令
    -> 归一化操作与完整能力集合
    -> Host Policy + 绑定审批
    -> 唯一 canonical Operation 记录与执行 handoff
    -> ProductSandboxFactory / 受控 HTTP 客户端
         -> 网络网关：域名、端口、地址与生命周期
         -> sandbox4cj：namespace、mount、环境、资源、seccomp
    -> 唯一 Receipt + ToolResult + terminal resolution
    -> durable recovery gate 或下一次请求
```

本计划不实现 TLS 中间人解密、数据防泄漏、浏览器执行、HTML reader-mode、认证网页读取、通用 UDP 转发或非 Linux 沙箱后端。域名授权约束申请的连接目的地，不证明获准服务器无恶意，也不能阻止任意程序主动使用 `-k`。内置 HTTPS reader 则必须验证证书和主机名。

## Approach

### 1. 以现有 NormalizedOperationPlan 和 canonical store 收敛准备与执行

目标：`agent_domain/src/operation_vnext.cj`、`tool_runtime/src/tools.cj`、`tool_runtime/src/prepared.cj`、`agent_core/src/core.cj`、`agent_core/src/tool_batch.cj`、`agent_runtime/src/operation_port.cj`、`agent_runtime/src/thread_runtime.cj`、`agent_store/src/operation_runtime_store.cj`、`persistence_runtime/src/sqlite_tool_repositories.cj`，以及实际 SDK、extension、program 调用点。

- 把每个工具的能力、effect、审批元数据和规范参数解析收敛成一个只读 resolve 步骤，返回 `Result<NormalizedOperationPlan>`。沿用 `normalizedToolOperationPlan` 的唯一编码和 binding 算法，不再分别从原始参数重算几个可能分歧的权限视图。
- `ToolDescriptor` 保留模型定义、并发声明和 resolver。删除被 resolver 取代的分散 capability、additional-capability、side-effect、approval 回调。简单工具使用同一个标准 resolver helper，不建立旧接口适配层。
- resolver 允许读取需要冻结的本地事实，例如写入目标、URI handler 描述、hub 已存 spec、LSP 实际配置快照。不得创建进程、联网、写文件或提前申请网络 lease。
- `PreparedToolInvocation` 持有原始 call 与唯一 normalized plan。`ToolExecutor.execute` 接收 prepared invocation，而不是只有 raw `ToolCall`。执行读取已批准的规范参数、权限和目标，不从当前环境偷偷扩大权限。
- `ToolPipeline.prepare`、审批与执行检查改用同一 `OperationRuntimePort`。准备 canonical Operation，记录 binding approval，在真正调用 executor 前记录一次 Executing/handoff。Core 删除重复 prepare/handoff。执行前重新验证权限上限、实现身份和动态 spec 版本，变化返回已知的前置错误。
- Core 仍通过 `AgentThreadRuntime.resolveOperation` 原子提交 canonical Receipt 与 ToolResult。ToolPipeline 不再写另一份 receipt 或把 intent receipt 当作完成事实。`afterResultPersisted` 仅在 canonical 语义提交成功后调用。
- 删除 `tool_operation_intents`、intent receipt 的生产存储与解码路径。仍需独立执行的 SDK/program 子操作走现有 `prepareProgramSubOperation`，必须先有 canonical ToolCall，不保留“没有 Run 就退回旧仓库”的分支。
- 保留 `PermissionRepository` 作为 session grant 仓库；它不是第二份 Operation ledger。内存实现与 SQLite 实现实现相同 canonical 生命周期，用真实入口修订原先直接依赖旧 intent 仓库的测试。
- 使用已有 `OperationAttemptStage` 表达未执行和已 handoff，使用已有 `ToolResult(isError=true)` 表达已知失败。无需增加另一套 outcome enum。

### 2. 定义一套可执行的网络规则与完整审批范围

目标：`agent_domain/src/domain.cj`、`agent_domain/src/operation_vnext.cj`、`tool_runtime/src/tools.cj`、`persistence_runtime/src/runtime_codecs.cj`、`persistence_runtime/src/sqlite_tool_repositories.cj`、`agent_product/src/tools.cj`。

新建领域值 `NetworkPolicy`，包含 `egress` 与 `publish`。空值表示无出站、无宿主端口发布。`bash` 与 `hub.start` 使用同一 JSON schema：

```json
{
  "network": {
    "egress": [
      {"host": "api.example.com", "port": 443, "private_addresses": []}
    ],
    "publish": [
      {"host_port": 5173, "target_port": 5173}
    ]
  }
}
```

- `egress` 每项是一个精确 host 和 TCP port，不接受 `*`、域名后缀匹配、CIDR、空 host 或“全部网络”。端口范围为 1–65535。
- host 规范化为小写 ASCII DNS 名或规范 IP literal；去掉合法的单个末尾点。国际化域名使用明确的 A-label。拒绝 userinfo、控制字符、空标签、混淆编码和 IPv6 zone。合并重复规则，稳定排序后绑定审批。
- `private_addresses` 默认空。访问 loopback 或私网必须列出具体规范地址并经过同一次审批；不能只传一个扩大到整个私网的 Boolean。即使显式列出，也拒绝 unspecified、multicast、broadcast、link-local/metadata 目的地址。IPv4-mapped IPv6 按实际 IPv4 地址处理。
- 公网分类采用保守的固定前缀规则。IPv4 排除 `0/8`、`10/8`、`100.64/10`、`127/8`、`169.254/16`、`172.16/12`、`192.0.0/24`、`192.0.2/24`、`192.88.99/24`、`192.168/16`、`198.18/15`、`198.51.100/24`、`203.0.113/24`、`224/4`、`240/4`。IPv6 默认仅接受 `2000::/3`，再排除 `2001::/23`、`2001:db8::/32`、`2002::/16`、`3fff::/20`。显式 private 例外仅可来自 RFC1918、CGNAT、loopback 和 IPv6 ULA，仍硬拒绝已知 metadata 地址 `100.100.100.200`、`168.63.129.16`、`fd00:ec2::254`。这些是本产品的保守规则，不声称穷尽所有部署中的敏感服务。
- `publish` 仅把宿主 `127.0.0.1:host_port` 转发到该沙箱 `127.0.0.1:target_port`。不发布到 `0.0.0.0` 或局域网。不把监听权限解释成出站权限。重复宿主端口、冲突端口与代理保留端口必须在启动前拒绝。
- NetworkAccess capability resource 固定编码为紧凑 JSON 数组：`["egress",host,port,[private_addresses...]]` 或 `["publish",host_port,target_port]`。使用已有 canonical JSON 编码器，私网地址先规范化、去重、排序；拒绝未知形式。输入、审批、persisted plan、broker 校验与执行共用编码器，禁止解析 shell 文本来推导权限。
- `NormalizedOperationPlan` 保存规则的类型化快照；原 `resolvedHosts` 改为从该快照导出的展示信息，不成为另一份可独立修改的权限事实。规则、spec generation 和相关配置身份进入现有 `bindingDigest`。
- session grant 改为 `toolName + 完整 requiredCapabilities 集合`。每个请求能力都必须被覆盖；workspace 路径保留按路径组件的包含规则，网络按规范规则做集合覆盖。空网络 scope 不能视为 session grant 的通配符。较窄权限可复用较宽但明确批准的同工具 grant，新增 host、port、private address 或 publish 必须重新审批。
- 从展示 metadata 中移除授权 scope 的所有权，由 Host 根据 normalized plan 生成 grant。Extension 可以提供展示信息，不能伪造或扩大 scope。
- TUI、CLI、RPC 审批显示命令/服务、cwd、读写范围、全部出站规则、私网例外、发布端口，以及 restart/persist/detached 语义。`askOnNetwork` 控制交互提示，不改变 OS 强制边界。

### 3. 实现保留私有 namespace 的网络网关

目标：新增 `agent_product/src/network_gateway.cj`、`libs/sandbox4cj/src/network.cj`、`libs/sandbox4cj/native/sandbox4cj_native.c`、`libs/sandbox4cj/native/sandbox4cj_native.h`、`libs/sandbox4cj/native/sandbox_net_bridge.c`，修改 `libs/sandbox4cj/src/sandbox.cj` 与对应构建清单。

职责分开：Product 网关做 Agent 授权、目的地址策略和 lease 管理；`sandbox4cj` 提供通用 socket、relay、bridge 与内核限制，不依赖 Agent 包。

- 移除 `NetworkIsolationMode.Allowed`。新机制仅有 Denied 与 Mediated；两者始终使用 `--unshare-net`、隔离 PID、禁用后续 user namespace，并在启动目标程序前去除 capability。没有“不支持就共享宿主网络”的退路。
- 有 egress、publish 或 namespace 内 port readiness 的执行配置获得 `NetworkLease`。lease 记录 owner、canonical operation/config authorization、规则、进程 generation 与生命周期，拥有私有 0700 目录中的 0600 Unix endpoints。只挂载该 lease 的 endpoints，不挂载整个宿主 runtime 目录。纯离线且不需要控制通道的进程仅运行限制安装器，不创建 gateway endpoint 或代理 listener。
- 采用单独的 native `sandbox-net-bridge` 可执行文件，不把整个 Agent 可执行文件和 SDK 运行时放进任意命令沙箱。bridge 只做进程启动、局部 TCP 到 Unix relay、控制通道和内核约束，不决定域名权限。
- helper 的执行字节在受信 composition 阶段校验并快照到 workspace 外的私有 runtime 目录，目标只读挂载这份快照。不能把可由模型修改的开发树 helper 路径当作长期可信执行文件。配置重载重新校验身份；现有 lease 不采用变更后的文件。
- bridge 在沙箱私有 loopback 开代理入口，向目标程序注入受控 `http_proxy/https_proxy` 与 `HTTP_PROXY/HTTPS_PROXY`，以及 `ALL_PROXY/all_proxy=socks5h://...`。`NO_PROXY/no_proxy` 为空。目标 env 中冲突的保留代理参数在前置检查报错，不能静默替换。
- bridge 自身以受信且去掉 loader 注入变量的环境启动；目标程序的已批准环境在安装限制后才生效。bridge 设置不可 dump，并不向目标继承 gateway/control socket。子进程执行任意程序、设置 LD_PRELOAD 或再次执行 bridge 都不能解除继承的限制。
- 目标执行前必须设置 `PR_SET_NO_NEW_PRIVS` 并加载不可放宽的 seccomp 过滤器；安装失败时不执行目标。bridge 的代理请求 endpoint 与可信控制/data endpoint 分开，目标不能通过普通代理连接构造控制帧或申请额外端口发布。
- native 子进程过滤器禁止创建 AF_UNIX pathname/abstract sockets，防止经 workspace 或只读 mount 中的宿主 socket 绕过网络规则。允许仅在本进程树内创建的 Unix socketpair。拒绝 socket 旁路所需的 AF_PACKET、AF_NETLINK、原始网络 socket、io_uring 网络路径、namespace 与 mount 重配置；覆盖 x86_64 和 x32/非预期 syscall ABI 的拒绝行为。
- 保留调试器对子进程的必要调试行为，但不能 ptrace、读取或复制 bridge 的内存/FD。通过独立 PID namespace、去 capability、bridge 非 dump 属性和关闭继承 FD共同保证；加入真实攻击式回归，不以配置字符串作为证明。
- 目标仅保留获准的 stdin/stdout/stderr 和明确协议所需 FD。修订 `process4cj` 的 native spawn FD 管理，关闭其余继承 FD，避免已有宿主连接变成出站旁路。保留 LSP、DAP、MCP 的原始 stdio framing，不输出 bridge banner 到协议流。
- 网关支持 HTTP forward proxy、CONNECT 和 SOCKS5 CONNECT；SOCKS 使用远端域名解析，不提供 BIND 或 UDP ASSOCIATE。HTTP parser 限制 header、处理 Host/absolute authority 一致性并拒绝歧义 framing；每个新请求/隧道都验证规则，不能靠第一条获准请求打开任意后续目的地。
- DNS 仅由受信网关解析。逐次连接检查全部候选地址：任何未批准的非公网地址都使该次解析失败。随后使用已检查的数字 sockaddr 连接，禁止在连接阶段再次按域名解析。设置 DNS deadline，并保留原 authority 供审计；不能只依赖 `isGlobalUnicast()` 判断私网。
- DNS 使用固定大小 worker pool（最多 8 个解析，32 个排队请求），不在 UI 或执行协调线程同步阻塞。取消或 deadline 后的迟到结果不得发起连接；底层解析尚未返回的 worker 仍计入上限，不能通过重试无限创建线程。
- native socket/relay 层提供数值地址连接、双向 bounded relay、half-close、deadline 和 close。网关使用这个窄机制，避免因 std socket 没有已确认的 half-close API 而在 EOF 时丢尾部数据或挂起。
- 连接 header 上限 16 KiB，每个 lease 最多 64 条并发连接，双向各 64 KiB 缓冲；DNS/连接期限各 10 秒，未完成代理握手期限 5 秒。已建立 tunnel 的空闲时间不等同于操作总期限，生命周期由所属请求或 daemon 控制。relay 不累计整个响应。
- gateway 丢失、bridge 异常、限制安装失败、owner 取消或进程退出时关闭 lease。网络设施异常时终止受影响目标进程，不能留下权限不明的长期 shell。只取消对应 owner，不影响并发请求。
- native helper 可提供受限的 SOCKS stdio-connect 模式，供显式 SSH ProxyCommand 使用。不会改用户 Git/SSH 全局配置。忽略代理的客户端连接失败，不自动升为宿主联网。

### 4. 合并沙箱构造、CA 与长期进程生命周期

目标：新增 `agent_product/src/process_sandbox.cj`，修改 `local_infrastructure.cj`、`direct_process_sandbox.cj`、`process_supervisor.cj`、`process_broker.cj`、`task_product.cj`、`lsp_runtime.cj`、`dap_runtime.cj`、`debug_tool.cj`、`mcp_runtime.cj`、`product.cj`、`config.cj`。

- `ProductSandboxFactory` 是三处生产 policy 构造的唯一入口。复用 `WorkspaceSandboxPolicy`，一次持有已解析 toolchain mounts、PATH、资源默认值和 `TrustRoots`，返回 launch plan、redactor 与拥有 lease 的句柄。不再复制完整沙箱配置类。
- `ProcessRequest.networkAccess`、direct launcher 的 networkAllowed、daemon/LSP/DAP/MCP 的 Boolean 全部替换为同一规则对象。模型进程不再有默认 Host 模式；受信剪贴板与固定产品维护命令走明确的 private host-utility 入口，不能从模型工具参数选择。
- `TrustRoots` 优先读取受信产品配置 `sandbox.ca_bundle`，否则按已验证的系统 bundle 候选路径选择存在、可读、非空的 PEM bundle：`/etc/ssl/certs/ca-certificates.crt`、`/etc/ssl/cert.pem`、`/etc/ca-certificates/extracted/tls-ca-bundle.pem`、`/etc/pki/tls/certs/ca-bundle.crt`。保留 authored 与 canonical symlink 路径并只读挂载，不能暴露整个 `/etc`。为命令设置选定的 `SSL_CERT_FILE` 和 `CURL_CA_BUNDLE`；native HTTPS 使用同一 roots，始终验证证书与主机名。
- 明确配置的 bundle 无效时 fail-closed。需要出站网络的命令配置或 HTTPS reader 在缺少系统 bundle 时返回 `sandbox.ca_unavailable`，不得注入 TrustAll 或重试 `-k`；纯离线命令和只做本地 readiness/publish 的服务不因此失败。TLS roots 由受信配置选择，不接受模型通过 tool env 替换。
- `DirectProcessHandle`、PersistentShell、PersistentEvalKernel、LSP/DAP client、MCP transport handle 与 daemon state 必须持有 lease 至自身关闭。close/取消/启动失败走同一幂等释放路径。DAP runInTerminal 子进程继承不大于已批准 adapter/debuggee 的规则。
- LSP 授权使用当前实际缓存的 spec，而不是一边读新配置审批、一边继续用旧 client。reload 先停止旧 client 与 lease，再对新快照执行授权。MCP/LSP 项目配置只提出权限；只有受信用户批准的配置快照可以授予服务联网，模型可写文件不能自行成为授权来源。
- `sandboxPlanProfile` 继续负责长期 shell/eval 复用。按规范规则和稳定配置身份计算，不把随机 socket 路径作为 identity，也不只比较旧 bwrap argv 而漏掉规则。离线、host A 和 host B 不得共用可泄漏状态或权限的 kernel。改用增量长度编码 hash，避免构造完整拼接字符串再复制成字节数组。
- profile hash 仅作查找加速；命中后比较完整稳定配置与规范网络规则，再决定是否复用。它不是授权 MAC，散列相同不能单独证明两个权限配置相同。
- 把可用性探测改为进程内、稳定 backend/基础配置身份的成功缓存。配置或 helper 身份变化即失效，失败不缓存为永久可用。真实 launch 仍必须 fail-closed。只消除重复探测，不缓存授权或绕过每次绑定检查。
- 私有 loopback 的 `ready.port` 由 bridge 控制通道在目标 namespace 探测。它不要求出站规则，也不要求宿主 publish。删除任意 `ready.host` 外联探测，readiness 只描述当前进程 namespace。
- publish 使用独立控制/data 通道把宿主 loopback listener 转到对应沙箱端口。未获批的端口不会监听。`ready.port` 检查实际目标服务，不能把“host forwarder 已监听”误判成应用 ready。log 与 port 同时配置时仍同时满足。
- hub 保存完整规范 spec、generation、owner 与原 canonical authorization 引用，不只保存散列或 socket 路径。broker 收到启动/重启请求后，从 canonical 记录校验绑定和授权，不能继续只接收 raw ToolCall arguments。
- broker 校验 canonical 记录中的完整 normalized plan、批准状态、owner 与 generation，不只比较调用者提供的 digest 字符串。执行内容取自该已验证记录，不能把“digest 正确但 raw args 不同”的请求传给 supervisor。
- manual restart 是新的已授权操作，冻结原 spec/generation，并在执行时拒绝漂移。自动重启仅继承最初获批的相同 spec 和 restart/persist/detached 范围，每一代重新建立 lease。规则扩张、过期审批或无法校验原授权时停止并要求新的批准。
- local supervisor 与 external broker 各自拥有所属 lease。broker 崩溃后，非终态记录继续进入 recovery_required，不把 stale socket、旧 PID 或旧 grant 当成可以自动接管的健康服务。

### 5. 用已有 read 路由增加受控 HTTPS 文本读取

目标：`agent_product/src/internal_uris.cj`、`agent_product/src/tools.cj`、`agent_product/src/product.cj`、新增 `agent_product/src/https_uri.cj` 与 `agent_product/src/authorized_http.cj`、`agent_rpc/src/host_uris.cj`。

- 不增加 `http_read`、`curl_read` 或新的 SDK HTTP intent。注册内置、不可被 RPC 替换/注销的 `https` handler，保留一个 `read` 模型工具。
- 扩展 URI handler 的 resolve 合约，使 handler 一次声明规范 URL、required capabilities、effect、retry、审批信息和可写性。RPC handler 必须提供明确声明，Host 再与权限上限相交，不能默认退回 WorkspaceRead。`https` 的 write 必须在执行前拒绝。
- `read.path` 接受绝对 HTTPS URL。可选 `network.egress` 只用于明确的附加 redirect 目的地和 private address 例外，禁止 publish。初始 URL 的 host/port 自动形成申请规则，而不是自动获得授权。
- 使用 `stdx.encoding.url.URL.parse/resolveURL` 解析 URL；拒绝 userinfo、非 HTTPS scheme 和非法 authority。URL query 仍属于可能敏感的工具输入；展示和错误须经 redactor，不能承诺自动识别任意签名 token。
- `AuthorizedHttpClient` 是窄的 Product HTTP 机制，不复用带 Provider 身份、POST 和凭据语义的 `ProviderTransport.post`。使用 `ClientBuilder.connector` 经本次 lease 建立网关 tunnel，TLS 对原始 HTTPS authority 验证。显式关闭 ambient proxy、cookie jar、HTTP/2 push 和库 autoRedirect。
- 手动处理最多 5 次 redirect。每跳重新解析相对 URL、校验 HTTPS、检查已批准规则并重新做连接地址检查。跨域未获批时返回 `network.redirect_denied`，显示需追加的目标，不自动扩权；不把已收到的 redirect 当成下一跳访问授权。
- 不接受自定义 auth/cookie header、client certificate、provider credential 或 .netrc。HTML 作为原始 UTF-8 文本返回，不执行 JavaScript、不声称完成正文提取。
- 接受 `text/*`、`application/json`、`application/*+json`、XML 类文本 MIME。decoded body 上限 8 MiB，header 上限 16 KiB，connect 期限 10 秒，总期限 30 秒；未知 Content-Length 也逐块计数。请求 identity encoding，拒绝未支持的 Content-Encoding，不能让解压绕过 decoded 上限。无效 UTF-8、非文本媒体和超限分别返回明确错误。
- 输出沿用现有 read 的行范围、preview 与 artifact 行为。body 先受 8 MiB 硬上限约束，再交现有 String/artifact 接口，不在本次额外建设无限大小的流式文档仓库。
- 保留既有 `destination` 功能。指定 destination 时，在任何网络 I/O 前同时解析写入目标并批准 WorkspaceWrite 与全部网络权限，随后复用 atomic workspace writer；不得把下载保存变成隐藏的未审批写入。
- 对外部 GET 采取保守语义：`ExternalMutation`、`Never` 自动重试、`NeverReplay` 外部执行。成功的已有 receipt 仍可重放结果，不再次发请求。普通 HTTP 错误或完整观察到的取消/超时可形成已知失败结果；崩溃导致无法确认是否发送/完成时保留 Unknown。网络读不是因为 GET 方法名就变成 Safe。
- 取消以 operation/request identity 管理 client、response 和 lease，run 取消只关闭该 run 的资源。不能因多个 URI 请求共用 runId 而相互覆盖。

### 6. 迁移其余真实联网消费者，封住替代路径

目标：`agent_product/src/github_tool.cj`、`web_search_tool.cj`、`vnext_control.cj`、`lsp_runtime.cj`、`dap_runtime.cj`、`debug_tool.cj`、`mcp_runtime.cj`、`agent_extensions/src/extensions.cj`、`agent_sdk/src/extension.cj`、相关 manifest/config 解码。

- GitHub 的 `gh` 与 `git` 子进程走同一个 mediated launcher。根据已选 forge、操作与 repo remote 冻结所需 host/port，不使用无资源的 NetworkAccess。未知 remote、重定向下载 host 或 SSH 目标必须显式申请规则，不能通过 gh/git 隐式拓宽。
- web search 从已配置 provider endpoint 生成精确规则，现有 curl 可保留，但只能通过同一 launcher 与 lease。保留 `-q`、secret env/redaction、实际取消和超时语义；无需为了架构统一重写 Brave/Tavily/SearXNG 协议解析。
- isolated extension 的 manifest 网络声明传完整规则，删除 generic `network.access -> true`。SDK `networkHttp.resource` 不再被 Product adapter 丢弃。网络能力没有具体目的地且没有受信静态 endpoint 时，注册/准备明确失败。
- MCP stdio 属于已批准的长期服务配置。MCP HTTP 的连接器使用相同受控连接机制，endpoint/redirect 不能绕过规则。远程工具 annotations 不能自行授予网络。DAP attach 绑定明确 host/port，runInTerminal 不继承更宽宿主网络。
- 模型 Provider transport 是受信控制面，继续使用已配置 Provider endpoint 与独立凭据路径，不套用某条模型 shell 的 egress scope。不能把这个例外暴露成任意 URL 工具。
- 用户直接 shell 控制命令可以显式提交同一 NetworkPolicy；其授权来源标记为真实用户控制命令，不伪造模型审批，但使用相同 OS 隔离。模型不能选择该来源。
- 更新 workspace 外的 `sandbox_runtime` 镜像调用以符合新 sandbox4cj API，但不把它引入生产依赖，不保留旧 Boolean 网络接口。

### 7. 按效果证据处理失败，修复写入的前置检查

目标：`agent_product/src/local_infrastructure.cj`、`agent_product/src/tools.cj`、`tool_runtime/src/prepared.cj`、`agent_domain/src/operation_vnext.cj`。

- 删除“仅由 AgentErrorKind 决定可恢复”的全局 `recoverableExecutorError` 规则。executor 返回已知错误 ToolResult 必须有完整完成结果或明确的未执行证据；发生在可能产生副作用之后的异常不能因为 kind 是 Timeout/Transport 就当作安全失败。
- Write resolver 复用 workspace target 检查：立即父目录存在且为目录、目标类型正确、权限范围与敏感路径合法。默认不隐式 mkdir，不对某个示例路径做特殊处理。前置拒绝发生在 handoff 之前，模型可以看到错误并修正。
- 把 writeFile 分成 staging、publish 和结果确认三个明确阶段。staging 失败且临时文件清理可确认时返回已知未修改目标的失败。publish 后或 publish 是否发生无法判断时返回外层错误，让 canonical resolver 产生 Unknown。不要重写现有 atomic replacement 算法，也不要声称 rename 失败必然无副作用。
- 保留具体底层 code、phase、必要路径和原始 cause。既不能把每个文件异常都压成 Internal，也不能把所有异常都降为 InvalidInput。所有字段经过现有 secret redactor。
- 普通命令的可观察退出码与完整捕获的结果是已知完成，即使命令失败或留下部分业务修改，也不意味着“未执行”。状态、是否可自动重试和是否产生修改分别描述。
- 被终止的任意副作用进程若无法确定其效果，仍需 reconciliation。只对已知安全的取消路径继续同 session；不得为了让 Ctrl-C 后的演示继续而篡改 Unknown。
- 工具错误统一为结构化 `error` 对象：`code`、`kind`、`message`、`fields`，外层包含 operation/outcome/reconciliation 信息。复用一个领域编码器供 known failure 与 canonical error 使用，消除同一字段有时 string、有时 object 的 ToolResult 形态。JSON-RPC 保留协议规定的 error 外壳，把同一结构放入 data。

### 8. 让 canonical terminal resolution 与恢复门禁成为权威

目标：`agent_core/src/core.cj`、`agent_runtime/src/thread_runtime.cj`、`thread_coordinator.cj`、`recovery.cj`、`agent_store/src/operation_runtime_store.cj`、`thread_registry.cj`、`thread_commit_sink.cj`、`runtime_recovery.cj`、`persistence_runtime/src/sqlite_run_repository.cj`。

- `commitCanonicalToolAttempt` 返回并消费 `OperationTerminalResolution`。批量、审批恢复、program 子操作和已提交结果重放路径都使用 canonical stopping error，不再用原始 executor error覆盖它。Unknown 必须让 API、Run、Operation、ToolResult 一致呈现 RecoveryRequired。
- 语义提交已成功但投影失败时，恢复读取同一 canonical 结果；不得重复写文件、重新访问外部服务或追加另一条 ToolResult。
- 将“存在未解决的 canonical operation”纳入 Thread 的持久化 start/admission 与 delete 门禁。registry 的缓存命中也检查；最终 Turn-start 与 delete 的 SQLite 事务再次检查，防止热 runtime 或并发请求绕过预检查。
- 门禁依据未对账 Operation、handoff/receipt 缺口和必要的运行恢复事实，不只看 activeTurnId 或 RunState。历史 RecoveryRequired Run 在其操作全部对账后不应永久阻止新 Turn。
- `OperationRecoveryPlanner.inspect(threadId)` 检查该 Thread 的未完成操作，包括已结算 Turn、已有 Unknown receipt/ToolResult 的操作。已有 ToolResult 不再提前跳过 recovery_required。
- 执行已有可证明安全的 recovery actions：从 receipt 补 canonical result、推进已提交结果、完成已拒绝审批、恢复稳定审批等待。只在没有 handoff 或已有明确 safe/idempotent replay 依据时重试。Unknown 永不自动重放。
- 增加显式对账服务：列出原计划、操作 ID、phase/cause、现有 receipt 和证据缺口；接受 `applied` 或 `not_applied` 以及非空人工证据。以 operation ID、binding 与 revision 做事务校验。对账追加独立不可变事实，不覆盖原 Unknown receipt 或历史 ToolResult。
- 相同对账重复提交幂等，冲突对账拒绝。对账不自动重新执行原命令、不复活旧模型 continuation。所有未解决操作消除后只允许开始新的 Turn。无法判断效果时保留门禁，用户可改用健康的新 session。
- 对账属于真实用户控制面，不能作为模型可自行调用的工具或 extension intent。

### 9. 统一产品状态投影与显式对账入口

目标：`agent_product/src/application.cj`、`agent_cli/src/commands.cj`、`agent_cli/src/registry.cj`、`agent_app_protocol/src/protocol.cj`、`agent_rpc/src/product_rpc.cj`、`agent_app/src/main.cj`、`agent_tui/src/tui.cj` 及当前错误/审批呈现调用点。

- 在 `ApplicationSession` 增加一个统一的 outcome 处理函数。normal submit、resumeStartup、手动和自动 decide、handoff、plan correction、goal continuation 全部使用它。根据 canonical recovery status 更新 pendingRecovery、pendingApproval 与 currentRequest，移除分散的 try-find/遗漏分支。
- 每次切换、重开 session 都读取持久化 recovery status。pendingRecovery 只是 UI 缓存，不承担最终授权或 admission。被阻塞 session 的队列不得静默执行或丢弃。
- 新增 `/recovery` 与 `/reconcile <operation-id> applied|not_applied <evidence>`。前者只读，后者先显示绑定计划和后果，再通过真实用户确认完成；RPC 使用对应类型化 user command，不通过普通 model tool 发起。
- TUI 错误卡显示原 code/phase、Unknown 与需要对账的 operation ID，并给出 `/recovery` 和 `/new`。健康 session 不受其他 session 的缓存标志污染。审批卡显示完整网络规则和端口发布，不仅显示“NetworkAccess”。
- CLI、JSONL、RPC、TUI 与 dump 消费同一结构化错误事实。dump 可以说明它是当前请求视图，不能把缺失的底层 cause 猜出来补上。

### 10. 完成 native 包装与一次性切换

目标：`libs/sandbox4cj/cjpm.toml`、`scripts/prepare_native_deps.sh`、`scripts/package_candidate.sh`、`scripts/package_readiness.py`、`packaging/public-packages.toml`、根构建与已有 gate 清单。

- native helper 与 socket/relay 库使用当前 LLVM 15 构建链；helper 不依赖 Agent/SDK，只依赖明确的系统运行库。开发 wrapper 准备两个产物。candidate 显式打包 `libexec/sandbox-net-bridge` 与 native 库，不能期待 ldd 自动发现独立 executable。
- public sandbox4cj 源码包包含 native 源码、头文件和 helper 构建/安装规则；readiness staging 构建对应静态产物并运行消费者，不再只有 process4cj 的单文件特例。
- factory 通过受信安装路径定位 helper，验证缺失/不可执行时 fail-closed。沙箱仅挂载 helper 与必要依赖的只读路径。candidate 移到另一目录并清除 LD_LIBRARY_PATH 后，应用、helper、sandboxed command 都必须可运行。
- 新配置、daemon record、approval grant 与 canonical operation schema 使用新的明确版本。启动遇到旧版本时报告 unsupported version，不静默忽略记录、删除数据库、采用旧权限或杀死未经确认的旧 PID。需要验证的新运行使用新的状态目录。
- 不保留 Boolean 网络解码、旧 grant 字段 fallback、legacy intent 表的双写/双读、旧 ToolExecutor overload 或 raw broker launch fallback。所有实际调用点一次迁移。

## Verification

计划阶段只进行了源码、技能、只读 API 索引查询，以及 `bwrap --help` 检查；没有运行构建、测试、fixture 或服务。以下都是实现后的验收要求，不是已通过的结果。

### 证据入口与顺序

所有命令从已存在的仓库运行。SDK 使用 `$HOME/cangjie_sdk/daily`。保持 `AXYNDRA_CANONICAL_TARGET_ROOT` 未设置，否则下面的 support binary 路径会改变。

1. 先用最小确定性回归暴露已知缺陷，再实现对应步骤。纯新 API 的普通行为用实际 smoke 证明；只保留能捕获权限逃逸、重复副作用、并发/恢复或协议边界错误的回归。
2. 跑 `operation_domain_vnext_contract`、`tool_runtime_contract`，然后跑新增的 targeted canonical/reconciliation 分支。删除旧 intent 双账本的实现形状断言，保留消费者行为断言。
3. 用 `sandbox_contract` 的新 network 场景验证真实 bwrap，再跑完整 `sandbox_contract`、`direct_runtime_sandbox_contract`。固定 Linux gate 不允许把“不支持沙箱”记为通过。
4. 跑 `product_thread_runtime_contract`、对应 Product scope、native TLS、web-search fixture、真实 broker blackbox。
5. 构建一次实际 `agent_app`，跑新增 PTY variants 与相邻回归，再跑迁移后的 SDK、extension、MCP 和 package consumer contracts。
6. 独立切片全部合并后再运行一次现有 architecture、implementation 与 packaging gates。禁止各切片重复跑整仓 build/lint/格式化。

既有 Cangjie contract 命令模式（工作目录是 `support_tests/<contract>`）：

```text
AXYNDRA_SDK_ROOT=$HOME/cangjie_sdk/daily ../../scripts/pinned_cangjie cjpm build
AXYNDRA_SDK_ROOT=$HOME/cangjie_sdk/daily ../../scripts/pinned_cangjie target/release/bin/main
```

既有真实入口：

```text
scripts/pinned_cangjie cjpm build -m agent_app -o agent_app
scripts/pinned_cangjie python3 support_tests/process_broker_blackbox/check.py --candidate <absolute-agent_app>
bash support_tests/native_provider_security_contract/check.sh
scripts/pinned_cangjie python3 support_tests/tui_path_coverage/check.py --candidate <absolute-agent_app> --output <new-empty-evidence-directory> --case <case-id>
scripts/package_candidate.sh
```

web search 的工作目录为 `support_tests/web_search_contract`，构建后使用：

```text
../../scripts/pinned_cangjie python3 local_fixture.py --candidate target/release/bin/main
```

### 必须观察到的行为

| 边界 | 真实刺激与结果 | 主要证据位置 |
| --- | --- | --- |
| 完整授权 | 离线 bash session approval 后请求联网仍需新审批；A 不覆盖 B，新端口/private address/publish 也不被覆盖；拒绝时目标 fixture 请求数为零 | `tool_runtime_contract`、`product_contract`、TUI approval |
| 默认隔离 | 相同命令由 bash/hub 执行，缺省都无法到达宿主 fixture；批准精确目的地后可以，经代理访问其他 host/port 仍为零 | `sandbox_contract` 新 `network_contract.cj` 与 fixture orchestration |
| 旁路 | 清空 proxy env、NO_PROXY、裸 IPv4/IPv6 TCP、UDP、SOCKS IP 目标、workspace Unix socket、继承 socket FD、io_uring 和再次执行 bridge 都不能扩大权限 | 真实 namespace 内的攻击式 smoke；fixture/连接计数 |
| DNS 与代理协议 | mixed public/private answers、下一次 DNS rebinding、IPv4-mapped IPv6、authority/Host 不一致、超大 header、歧义 framing、并发上限与 half-close | 同一 gateway contract；数字目标 fixture 实际计数和完整尾部字节 |
| TLS | 新建测试 CA/leaf，明确信任后 curl 和 read HTTPS 成功且不使用 -k；不可信链、错主机名、无 roots 明确失败；机密不出现在证据中 | 复用 `native_provider_security_contract/fixture_server.py`，补正向 CA orchestration |
| 长期生命周期 | 相同 scope shell 可复用；不同 scope 不复用；取消仅影响本 owner；gateway 丢失关闭目标；LSP/DAP/MCP 正常 framing 与关闭保留 | `direct_runtime_sandbox_contract`、MCP、LSP/DAP 既有 contracts |
| readiness/publish | 无 egress 的私有 loopback server 能 ready；宿主同端口的无关服务不能误报；未 publish 无宿主入口，批准 publish 后可达；log+port 同时满足 | hub 实际进程与宿主连接 |
| broker | manual/automatic restart 仅访问原规则；spec 漂移拒绝；SIGKILL/takeover 保留恢复门禁、不自动继承 stale lease；stop/backoff 无泄漏 | `process_broker_blackbox/check.py` |
| HTTPS read | 有界文本与原始 HTML、JSON、同域与获批跨域 redirect、未获批跳转零请求、降级拒绝、超限、非法 UTF-8、压缩拒绝、取消与并发隔离 | 新 reader contract 放入现有 Product/read 与 URI 测试；T028 variant |
| 已知写失败 | 缺父目录、非法目标在 handoff 前拒绝，文件无变化，模型收到结构化错误后可以修正并继续 | `product_contract` 的真实 workspace + Provider tool loop |
| Unknown | 一次真实写入后注入结果持久化故障，写入只发生一次；Operation/API/Run 都是 RecoveryRequired；同 session 后续请求与删除被拒绝，Provider 不收到新请求 | `product_thread_runtime_contract`、真实 SQLite reopen |
| 对账 | 重开仍阻止原 session；健康新 session 成功；人工 applied/not_applied 对账追加事实，重复幂等、冲突拒绝，原错误证据保留；随后只开启新 Turn | 同一 durable Product contract + T027 variant |
| 包装 | relocated candidate 清除 LD_LIBRARY_PATH 后可启动 helper、执行真实 sandbox 网络请求；缺 helper/root/内核能力明确失败；SDK consumer 编译新接口 | candidate、public package readiness |

测试 CA、host/private address mapping 与故障注入只能通过已有或新的测试 composition seam 提供，不能增加生产环境变量形式的安全绕过。DNS 可用可注入 resolver 驱动重绑定序列，但连接、TLS、进程、文件与恢复必须真实发生。

### PTY 验收

扩展现有 `support_tests/tui_path_coverage/check.py`、`fixture_server.py`、`scenarios.json`，不另建模拟 TUI：

- `T028/https-read`：实际 read HTTPS tool call、成功/拒绝/取消、后续请求。Provider 返回至少三个有延迟且跨 SSE 边界的 chunk，保留 usage 与 terminal 反馈。
- `T029/network-policy`：离线与联网审批、真实 bash/hub 连接、私有 readiness、loopback publish、重启和退出。
- `T027/operation-reconciliation`：真实写入后持久化故障、Unknown 可见、同 session 门禁、`/new`、重开、`/recovery` 与人工对账。
- 回归 `T007/esc-cancel-recovery`、`T019/provider-errors`、T020 recovery variants、`T023/mcp-http`、`T026/copy-and-suspend`、`T027/restart-cycle`、`T028/builtin-boundaries`、`T029/task-process-boundaries`。修正 T007 缺少 `normal_exit()` 的验收缺口。
- 修订 `T021/tool-loop-cancel`：真实命令停止且 TUI 不挂起必须保留；不再无条件断言未知副作用的取消可以直接开启同 session 下一 Turn。已证明安全的取消覆盖同 session 继续，Unknown 覆盖门禁与健康新 session 继续。
- 保存真实键序列（Enter、Escape、Ctrl-C、`/exit` 与新命令）、fixture 请求、ANSI/terminal snapshots 和退出码。取消安全的 read 请求后同 session 可继续；可能修改状态且效果未知的取消明确要求对账，健康新 session 必须可继续。
- 不把现有矩阵声明当作执行证据。对文本、reasoning、tool、usage、错误、timeout、EOF 不完整事件和非法 UTF-8 选择现有相应 runner 或新增真实刺激，报告实际运行项。未执行的鼠标、resize 或其他终端能力明确列为未覆盖。

显著行为 smoke 通过后，更新现有 `docs/architecture.md`、`docs/runtime-capabilities.md`、`docs/compatibility.md` 及实际受影响的工具/配置说明，删除过时的 Boolean 网络和旧错误示例。按仓库文档技能完成编辑，不新建无关 README 或文档体系。移除实现期间的临时 smoke 文件，保留真正需要的回归和证据。

## Assumptions & contingencies

- 这是完整实施范围，不把真实域名强制、broker 生命周期、对账门禁或 native 包装留成占位。实施顺序是：冻结契约与单账本 → 网络机制和恢复机制分别实现 → Product 全调用点接入 → 真实行为与发行验证。
- 只对当前 Linux x86_64 backend 承诺实现证据。其他主机缺少所需 namespace/seccomp/helper 时拒绝执行，不做 Host fallback；不把当前主机结果外推成平台矩阵。
- 任意 TCP 客户端需支持 HTTP/SOCKS 代理或明确 ProxyCommand。UDP/QUIC 与无代理直连不受支持，错误中说明这一边界，不暗中授予宽网络。
- 系统 CA、第三方已批准 host 和命令远端本身仍是信任边界。域名代理不保证同 IP 虚拟主机之间的应用层隔离，不阻止获准服务器代转发，也不检查加密流中的业务内容；验收和文档不能作更强宣称。
- 旧配置和数据不迁移、不兼容读取，但也不静默删除。发现不支持版本时提供明确诊断，使用新状态目录进行验证；已有目录保留供人工处理。
- 此前那次 write 的真实 cause 和实际副作用仍未证实。实现回归分别构造“确定未执行”和“已产生效果但结果证据丢失”，不把假设写成事实。
- 当前未配置 Cangjie LSP。实现前若仍无 server，用精确符号搜索列齐上述导出签名的生产、SDK、extension、镜像 wrapper 与 testkit 调用点，并以编译验证干净切换；若配置了 LSP，先用 references/rename 工具。
- API 索引已确认 URL parser、ClientBuilder connector/proxy/cookie/push/redirect 与 TLS 配置入口，但尚未运行本 SDK 上的新 tunnel 组合。实现时先以本地 HTTPS fixture 证明该组合，不能以文档存在替代运行证据。
