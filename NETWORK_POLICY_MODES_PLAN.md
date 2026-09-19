# 三模式网络隔离、统一执行与恢复语义

## Context

合并本轮 Shell 网络计划与仓库中的 `网络隔离_PLAN.md`。用户已明确选择：**本次完整实现 restricted、proxy、trusted-host 三种模式**。这替代了较早的“本阶段不引入 proxy”，也替代了旧计划“移除所有宿主联网能力”。旧计划的 canonical 操作账本、域名网关、HTTPS read、恢复/对账、native 包装均在本次范围内。

高级模式只开放网络：文件与进程沙箱、readable/writable paths、环境白名单、secret policy、redaction、Capability 和 Approval 不因模式改变而放宽。Shell 使用宿主网络不等于 `ProcessSandboxMode.Host`。Provider 控制面与专用网络工具独立于 Shell 模式，不要求修改 Provider 服务器或系统 DNS。

### 合并后的唯一行为契约

受信配置键为 `shell.network_mode`，值严格为 `restricted | proxy | trusted-host`，缺省 `restricted`。适用于任意程序执行表面 `bash`、`hub.start` 及真实用户的 `axyndra shell`；`hub.restart` 使用原服务的已归一化 spec 并重新授权，而不是重新填当前缺省值。`bash_readonly`、plan-only 子代理与 eval 固定 Denied。LSP、DAP、MCP、isolated extension 和专用工具按自己的受信配置/请求规则联网，不继承此缺省值。

模型可提交的 `network` 是请求，不是开关或授权来源：

```json
{"network":{"mode":"host"}}
{"network":{"mode":"denied"}}
{"network":{"mode":"proxy","egress":[{"host":"api.example.com","port":443,"private_addresses":[]}],"publish":[]}}
```

| Shell 配置 | 缺省请求 | 显式 denied | 显式 proxy + 规则 | 显式 host |
| --- | --- | --- | --- | --- |
| restricted | Denied | Denied | Mediated；能力检查与审批 | HostNetwork；能力检查与单次审批 |
| proxy | Mediated，空规则，无外联 | Denied | Mediated；能力检查与审批 | 前置拒绝 `network.mode_denied` |
| trusted-host | HostNetwork；仍检查能力和审批 | Denied | Mediated；能力检查与审批 | HostNetwork；仍检查能力和审批 |

- `bash`、`hub.start` 共用上述network对象，替换hub原Boolean字段；`network` 一旦出现，必须有 `mode`。Denied/Host 不得带 egress/publish；Proxy 才能带规则。拒绝未知键、Boolean旧输入和非对应模式字段，不静默忽略。
- `bash`不接受publish，监听服务用hub。HostNetwork或Mediated Bash一律一次性process tree，不进入持久shell cache；执行最终完成/取消/超时销毁全部后代。起始cwd为显式workspace内cwd，否则workspace root；不继承或写回离线shell的cd/export。Denied Bash保留既有持久行为。async的running回执仅表示同一已批准job已接管，权限持续至该job终态，不是第二份授权；同步PTY使用相同网络策略，async+pty仍拒绝。
- `hub` 的授权覆盖一个明确 service spec 及其原本批准的 restart/persist/detached 生命周期；不是会话级“任意程序联网”。restricted 中手动启动的 HostNetwork 仅属于该 service tree；自动重启必须已在原 spec 中显式批准，不能因一次 Bash 授权获得服务授权。每一代重新建立拥有者与资源。
- HostNetwork 明确允许宿主可达的 TCP/UDP、DNS、loopback/私网与监听；不声称具备域名/端口约束。没有产品强制 proxy 或 network namespace。仍只注入显式允许的环境；不自动继承宿主代理或凭据。
- Proxy 与 Denied 均强制私有 network namespace，禁止利用宿主 Unix socket、继承 FD 或 namespace/syscall 绕过。Proxy 不可用时失败，不升级 HostNetwork；没有自动重新执行失败命令的“联网重试”。
- `askOnNetwork` 只控制现有审批策略，不改变隔离。manual/AI/never/trusted 路由保持各自语义；trusted/Yolo 是既有、独立的审批设置，不是 trusted-host 的别名。无 NetworkAccess capability 时任何审批答案都不能加权。HostNetwork与所有联网Bash均不允许ApproveSession；每条Shell命令仅获本次process tree授权，使用一次性审批或已显式配置的静态审批策略，不从先前Shell审批派生后续权限。
- 模式变更需要重开ProductRuntime，不新增热切换。现有实例的Run、新session和子代理都保持启动快照；config set只改变持久设置，显示restart-required。重开后新操作用新设置，尚待执行的审批重新校验。模式变更不是撤销已有服务：存量服务显示实际策略，需显式hub.stop关闭；manual restart是新操作，检查当前上限，不修改原spec“适配”模式。

### 源码锚点

本轮已读的五处关键依据：

1. `agent_product/src/tools.cj:637-699,2617-2788`：Bash schema 无网络字段；PTY/普通分支均使用缺省 networkAccess=false；readonly 有独立限制。
2. `agent_product/src/local_infrastructure.cj:1358-1412,1772-1858,2033-2159`：持久 shell cache、profile 与命令完成并不等于进程树退出。
3. `libs/sandbox4cj/src/sandbox.cj:397-432,493-629`：现有 Allowed 仅省略 `--unshare-net`；文件、环境和进程策略是独立维度；稀疏 `/etc` 未提供 CA。
4. `tool_runtime/src/tools.cj:630-787,916-951,1842-1936,2226-2247`：准备阶段检查完整能力并绑定 normalized plan，但 session grant 仍仅匹配 metadata scope。
5. `agent_runtime/src/operation_port.cj:7-39`、`agent_domain/src/operation_vnext.cj:135-211`：已有 canonical Operation port 与 normalized plan，应扩展它们而非引入平行 ExecutionPolicy 或授权散列。

## Approach

### 1. 冻结领域值、三模式配置与完整授权范围

目标：`agent_domain/src/domain.cj`、`operation_vnext.cj`，`tool_runtime/src/tools.cj`、`prepared.cj`，`agent_product/src/config.cj`、`product.cj` 与 CLI/配置写入调用点。

**领域契约：**

- `agent_product/src/config.cj` 新增 `ShellNetworkMode { Restricted | Proxy | TrustedHost }`、`parseShellNetworkMode(value: String): Result<ShellNetworkMode>` 与 `shellNetworkModeName(mode: ShellNetworkMode): String`，表示受信用户缺省；模型schema不能设置该配置。NetworkPolicy及规则类型放agent_domain，底层库不反向依赖Product。
- `NetworkPolicy` 是不可变值，包含 `mode: NetworkPolicyMode`、`egress: Array<NetworkEgressRule>`、`publish: Array<NetworkPublishRule>`；`NetworkPolicyMode { Denied | Mediated | HostNetwork }`。规则字段为 `host: String, port: UInt16, privateAddresses: Array<String>` 与 `hostPort: UInt16, targetPort: UInt16`。只有 Mediated 能含规则。parse/normalize 返回 `Result<NetworkPolicy>`，无效输入在任何 I/O 前拒绝。
- `ProcessRequest.networkAccess`、direct launch 的 networkAllowed、daemon/LSP/DAP/MCP/extension 的网络 Boolean 全部迁移为该类型。模型进程请求不再缺省 Host filesystem/process 模式；受信剪贴板与固定维护命令使用不可由模型选择的 private host-utility 入口。`sandbox4cj` 不依赖 agent_domain，只接收 Denied/Mediated/HostNetwork 网络机制及相应 launch bindings。
- `NormalizedOperationPlan` 增加规范网络策略、审批元数据和受信配置/spec generation；`canonicalArguments` 中显式保存已解析的网络模式，执行不得再次从配置或 raw call 填缺省。模式、全部规则、generation、实现身份、cwd、环境和全部能力进入现有唯一 `bindingDigest`。`resolvedHosts` 仅从规则导出展示，不能单独修改为另一份授权事实。

**规则：**

- Egress 为精确 host + TCP port；端口 1–65535。拒绝 wildcard、后缀授权、CIDR、空 host、userinfo、控制字符、非法空 DNS 标签、混淆编码与 IPv6 zone。小写 ASCII DNS/A-label 或规范 IP literal，移除合法的单个末尾点；规则及地址去重、稳定排序。
- 私网默认拒绝。具体例外列在 `private_addresses`，与 host/port 一次审批；没有“允许全部私网”的 Boolean。IPv4-mapped IPv6 先按实际 IPv4 分类。
- 公网分类固定、保守：IPv4 排除 `0/8,10/8,100.64/10,127/8,169.254/16,172.16/12,192.0.0/24,192.0.2/24,192.88.99/24,192.168/16,198.18/15,198.51.100/24,203.0.113/24,224/4,240/4`；IPv6 仅接受 `2000::/3`，再排除 `2001::/23,2001:db8::/32,2002::/16,3fff::/20`。private 例外仅支持 RFC1918、CGNAT、loopback、ULA；unspecified/multicast/broadcast/link-local 及 metadata 地址 `100.100.100.200,168.63.129.16,fd00:ec2::254` 始终拒绝。这不承诺识别所有部署中的敏感服务。
- publish 仅是宿主 `127.0.0.1:host_port` 到同一沙箱 `127.0.0.1:target_port` 的转发。不得监听 0.0.0.0/LAN；不得产生 egress。重复、占用和保留端口启动前拒绝。
- NetworkAccess resource 的唯一 canonical JSON 编码：`["host"]`、`["egress",host,port,[private_addresses...]]`、`["publish",host_port,target_port]`。拒绝未知形式。HostNetwork 不伪装成空 host 或 wildcard egress。Run 的既有无 resource NetworkAccess 仅可作为受信 composition 提供的申请资格上限；resolver 产生的实际操作权限必须具体，不将此空值存成审批 grant。
- `PermissionRepository` 改为保存 Host 生成的 `toolName + implementation identity + 完整 requiredCapabilities`，不从 extension 可供展示的 metadata 获得授权 scope。workspace仍按路径组件包含；proxy按规则集合包含。网络资源为空的grant只覆盖离线；不同工具、新增host/port/private/publish或HostNetwork都不被旧grant覆盖。HostNetwork及联网Bash的ApproveSession返回`approval.session_scope_forbidden`，UI/protocol不提供该选项；同一命令再次请求也不能命中旧Shell网络grant。专用工具可保留相同/更窄proxy规则的session审批，Hub可批准具体service生命周期；它们每次执行或每代服务仍建立独立lease，不借用Shell权限。
- 审批展示完整能力、effective mode、是否宿主私网可达、cwd、文件范围、规则、生命周期及权限来源；AI reviewer 必须批准完整集合，不能只回主能力标签。任意脚本有网络权限就标记 network 风险，不依赖 `curl`/`npm` 字符串识别。绑定漂移返回已有 `tool.approval_context_changed`，能力撤销返回 `tool.capability_denied`。
- `tool.approval_requested`、批准、拒绝、执行/终态 audit 从 normalized plan 输出完整 `required_capabilities`、`network.mode`、规范规则、operation/owner/generation 与来源，不再只记录primary capability；secret值不进入这些字段。MemoryPermissionRepository 与 SqlitePermissionRepository 使用同一集合匹配，删除现有SQLite硬写 session_only=true 的旧语义。

**配置与入口：**

- `ProductSettings` 新增 `shellNetworkMode: ShellNetworkMode = Restricted`、`sandboxCaBundle: String = ""`；`ProductConfig` 新增 `shellNetworkModeOverride!: ?ShellNetworkMode = None`。`openProduct`唯一合并优先级：显式受信CLI/SDK override > settingsRoot/config.yml > Restricted，构造 `ProductRuntime.shellNetworkMode` 不可变字段。只用既有用户根AXYNDRA_HOME/~/.axyndra，不增环境变量mode开关、project/session设置或provider字段。
- 修改`loadProductSettings`、`validateProductConfigSource`和mapping-shape校验，严格解析shell.network_mode与sandbox.ca_bundle；重复段/键、非法值/结构均config.invalid。按本次不兼容切换决策，用户config.yml增加顶层`schema_version: 1`；文件不存在时使用新缺省，首次写入生成该字段；已有文件缺少或不支持版本时config.unsupported_version且不改文件。新版本继续保留其他future顶层键行为。所有持久修改用lossless ProductConfigEdit，不采用无人调用的encodeProductSettings重写全文件；配置生成入口与fixtures同次迁移。
- `agent_app/src/main.cj` 的主ProductConfig、local-maintenance副本、`acpSessionProductConfig`均传递override。CLI新增全局 `--shell-network-mode`，支持分离值与等号形式；在direct command分派前无条件校验非法/缺值并退出2。同步修改 `directCliCommandIndex`、`argumentParseError.valueOptions`、`withoutRuntimeArguments` 与help；`--`之后的同名文本仍是literal prompt。
- 既有config list/get/set/reset（文本/JSON）加入shell.network_mode与sandbox.ca_bundle；mode reset回restricted，CA reset回空值自动选系统bundle。schema_version可展示但不可由set/reset改写。失败不写文件，其他model/async/theme/provider编辑保留新键/comments。config展示持久值，/settings展示当前实例有效值，两者不混淆。
- task不新增模型可控mode override，子代理继承父快照/权限上限，只读子代理固定Denied。ACP每次新建ProductRuntime重新读用户配置，但显式CLI override仍优先；已存在实例不重载。待审批操作重开后重新绑定，不能按新宽权限执行旧批准。
- 非TUI `ApplicationSession.settingsCommand` 显示有效模式；TUI新增 `AgentTuiBackend.currentShellNetworkMode(): String`，在ProductTuiBackend实现并用于/settings的非选择性信息文本，不放一个无动作的菜单项。`welcome()` 在trusted-host显示常驻Warning：宿主网络开放，文件/环境/凭据/审批保持独立。不开live toggle。
- 真实用户 `axyndra shell` 增加 `--network <denied|host|proxy>` 与 `--network-policy <json-file>`（仅 proxy 使用，文件内容是同一 egress/publish 对象，shell 禁 publish）；交互中每一条命令使用当前显式选择。用户输入只能走受信 control-command authority，记录来源，不伪造模型审批；模型无法通过参数选择该来源。缺省仍由 shell.network_mode 决定，联网命令一次性，`.help`/`--snapshot` 不宣称跨联网命令保存环境。
- 同步迁移 `ProductRuntime.executePersistentShell`、`executeBash`，`ApplicationSession.executeBash/executeBashAsync` 及其application/RPC user-command调用点。它们当前绕过ToolPipeline，不能直接把缺省网络改成true。经真实user-command边界创建具备actor/source的canonical操作和同一网络/沙箱plan；所选host模式作为用户本次命令授权，不写模型/session grant。CLI的network-policy文件仅在受信控制入口读取，内容校验后冻结进plan，executor不再读文件。
- Bash结果的 `cwd` 对联网一次性执行表示规范起始cwd，而不是最终PWD；单独解析call.cwd并填入ProcessRequest.workingDirectory，不只拼接cd前缀。未联网持久Bash继续返回最终PWD。tool schema说明该差异，真实契约不把历史持久状态错误继承给联网调用。

### 2. 以 canonical Operation 收敛准备、审批与执行

目标：`tool_runtime/src/tools.cj`、`prepared.cj`，`agent_runtime/src/operation_port.cj`、`thread_runtime.cj`，`agent_core/src/core.cj`、`tool_batch.cj`，`agent_store/src/operation_runtime_store.cj`，`persistence_runtime/src/sqlite_tool_repositories.cj`，所有 SDK/extension/program executor。

- 新 resolver 签名为 `(ToolInvocationContext, ToolCall) -> Result<NormalizedOperationPlan>`，只读解析参数、资源、权限、effect、retry、审批及配置快照；可读取需冻结的路径/handler/spec，不允许启动、联网、写文件或申请 lease。沿用现有 binding 编码，不添加另一份 policy/hash。
- ToolDescriptor保留definition、concurrency、resolver，以及仅用于catalog曝光的 `visibilityCapabilities: Array<Capability>`。删除旧capability/additional-capability/side-effect/approval授权回调；简单工具使用同一标准resolver helper。`definitionsFor`只用visibility floor筛选，不调用缺参数的resolver；该floor不能授权执行，最终能力一律来自plan。Bash的可见floor为ProcessSpawn，readonly为WorkspaceRead，专用网络工具为NetworkAccess。
- `ToolExecutor.execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult>`；prepared 持有原 call 和唯一 normalized plan，删除可独立漂移的 capability/binding 副本。executor 只消费规范参数、网络策略与已冻结配置，不执行 raw call。取消继续使用已有 owner/operation identity，不把不同 operation 压成同一 runId 槽位。
- `BashReadonlyTool`对Bash实现的内部委托与ProductExtensionOperationHost等直接executor调用一并迁移，传同一prepared或真正的canonical子操作，不手造“已批准”prepared。readonly保持WorkspaceRead floor及RO/Denied plan，不因实现内部spawn而要求普通Bash的ProcessSpawn/NetworkAccess。
- Product仅构造一个`DurableOperationStore(database)`并把同一`OperationRuntimePort`传给ToolPipeline、Core和program执行；SDK也共享同一个升级后的InMemoryOperationRuntimePort及terminal sink，不再由Core暗建另一个实例。pipeline依赖改为该port，准备一次canonical Operation、批准后且真实调用前只写一次Executing/handoff。执行前重新只读resolve当前descriptor/spec，与stored完整plan比较并检查能力上限；不重新填不同缺省后直接执行。
- `CapabilityPolicy.evaluate(context: ToolInvocationContext, plan: NormalizedOperationPlan): PolicyDecision` 替换descriptor参数，统一读取plan全部能力、effect与审批元数据。`approvalHash`当前是FNV-64，只能用于索引/关联；审批和执行必须与canonical store的不可变完整plan作规范内容比较，再检查revision/owner/批准状态，不能仅凭digest相等放行。broker与profile遵守同样规则，不新建平行授权MAC。
- 正常执行经`AgentThreadRuntime.resolveOperation`提交Receipt、ToolResult和terminal resolution。managed晚到终态与显式recovery使用其同一canonical终态编码和transaction writer，仅按各自持久owner/CAS规则进入，不复制另一套receipt实现。Core移除重复prepare/handoff；ToolPipeline不写intent receipt；afterResultPersisted只在对应canonical语义提交成功后触发。
- 删除生产`tool_operation_intents`/intent receipts、`OperationRepository`、SqliteToolOperationRepository、MemoryOperationRepository及reset/GC引用。迁移`agent_ports`、`agent_testkit`、`agent_embed/src/sdk.cj`、`vnext_control.cj`和所有消费方；移除`AgentBuilder.operations(OperationRepository)`旧依赖，不留alias。保留PermissionRepository，也保留WorkspaceMutationPort仍使用的普通OperationReceipt，不能按同名误删。
- `prepareProgramSubOperation`当前仅在DurableOperationStore具体类，必须提升到OperationRuntimePort：`prepareProgramSubOperation(operationId: OperationId, runId: RunId, toolCallItemId: ItemId, plan: NormalizedOperationPlan): Result<Unit>`，内存/持久实现一致。入口先提交canonical ToolCall Item，再准备子操作。删除generic PipelineProgramSubOperationExecutor的raw/legacy fallback；SDK/direct调用必须建立相应canonical上下文。
- async Bash沿用`ProductTaskRuntime.startBashJob`/jobId/取消/结果通知语义，冻结prepared plan而非捕获raw call重新解析。父操作的running回执只证明一次性受控job handoff，不是命令完成；执行子操作及最终结果使用同一canonical terminal writer，job状态只作生命周期/展示投影。显式记录父操作→唯一job execution、授权引用与owner/instance generation；子操作不另获一份更宽审批。支持已批准的managed执行在父Turn结束后提交终态，校验该持久handoff/owner而非借当前Turn身份写入；正常完成门禁认可这种已证实的职责移交，不将仍由有效owner管理的job误判为Unknown。缺owner或丢终态证据才进入recovery。async的网络权限止于该job最终完成/取消/超时，不是在running回执发出时撤销；保留async+pty拒绝，不新增组合支持。
- Effect 与 retry 独立于成功/失败。沿用 `OperationAttemptStage`、`ToolResult(isError=true)`、`OperationTerminalResolution`，不再增加重复 outcome enum。

### 3. 实现 Proxy/Denied 的真实内核边界与网关

目标：新增 `agent_product/src/network_gateway.cj`，`libs/sandbox4cj/src/network.cj`、`native/sandbox4cj_native.c`、`.h`、`native/sandbox_net_bridge.c`；更新 `sandbox.cj`、process4cj spawn FD 路径及构建清单。

- Product 网关决定授权、目的地址与 lease；sandbox4cj/native 只提供 bridge、socket、relay 和内核限制。Mediated/Denied 都有 private network/PID namespace、去 capabilities、禁后续 user namespace；HostNetwork 明确不 unshare-net、不创建 proxy，不应用网关目的地址限制，但保留共同文件/进程/环境隔离。
- 单独 native `sandbox-net-bridge` helper，不把完整 Agent/SDK 放入任意命令沙箱。受信 composition 校验其字节并快照到 workspace 外私有 runtime 目录，只读挂载；模型可写的开发树 helper 不作为长期执行身份。配置重载重新校验，已有执行不替换字节。
- 需要 egress、publish 或私有 namespace `ready.port` 的执行在 canonical handoff 后获得 NetworkLease。lease 绑定 operation 或已批准配置引用、owner、完整规则、generation、deadline；拥有 0700 私有目录和 0600 endpoints，只挂本 lease endpoints。纯离线不需要控制通道时不建 proxy listener。
- bridge 提供私有 loopback HTTP/CONNECT 与 SOCKS5 CONNECT 入口；受控 HTTP_PROXY/HTTPS_PROXY/http_proxy/https_proxy/ALL_PROXY/all_proxy 指向此入口，NO_PROXY/no_proxy 为空。Mediated 下模型 env 对保留 proxy 参数的覆盖启动前报 `network.proxy_environment_conflict`，不静默替换。HostNetwork 不自动读取宿主 proxy env，也不禁止用户已批准的显式 proxy 参数。
- bridge 自身环境去除 loader 注入变量，设 non-dumpable；只在安装限制后把批准环境传给目标。目标先 `PR_SET_NO_NEW_PRIVS`，再安装不可放宽 seccomp；失败不 exec。可信 control/data 与普通代理请求 endpoints 分开，普通连接不能提交控制帧或创建端口发布。
- 启动通道不依赖不存在的 `bwrap --preserve-fds`。Product预建一次性0600 Unix bootstrap端点；bwrap argv仅含受信helper、固定版本/模式/端点路径，不重新拼接模型argv/env。helper连接后读取已冻结executable/argv/cwd/env，宿主校验SO_PEERCRED、预期bwrap树内PID/starttime和helper快照身份，消费pending启动记录并关闭bootstrap，再允许target启动。HostNetwork和纯Denied不挂持久gateway端点；Proxy/内部readiness只挂本lease的独立control/proxy/data endpoints。
- native协议使用固定magic `AXYN`、u16版本1、u16类型、u32 payload长度、u64 requestId，均网络序；payload为长度前缀UTF-8字符串/定宽数值/有界数组，不引入native JSON库。bootstrap描述≤1 MiB，普通control帧≤16 KiB；长度在分配前检查，拒绝NUL、未知类型和尾随字节。运行control承载ready/probe/open-target/exit/close，data用一次性channelId握手后成为字节流。普通HTTP/SOCKS入口没有控制解释器；publish channel只由已批规则创建。target不继承任何这些FD或控制面凭据。
- Denied/Mediated只允许普通AF_INET/AF_INET6 socket；`socket(AF_UNIX)`等其他domain、raw socket、io_uring和namespace/mount重配置拒绝。保留进程树IPC的精确范围是`socketpair(AF_UNIX, SOCK_STREAM | 合法CLOEXEC/NONBLOCK flags, 0)`；DGRAM/其他类型不能借socketpair获得可重新寻址的宿主Unix通道。过滤只检查syscall标量参数，不假装classic seccomp能检查sockaddr指针。拒绝x32/非预期ABI；clone3返回ENOSYS以走可检查flags的clone路径。保留调试器对子进程的ptrace，不全局禁止调试；bridge保持non-dumpable、无可继承FD且目标无CAP_SYS_PTRACE，以内核访问检查阻止读取/复制bridge内存/FD。依据[connect(2)](https://man7.org/linux/man-pages/man2/connect.2.html)的Unix stream单次连接语义；必须用重连、SCM_RIGHTS与bridge攻击实测证明，不能只检查BPF文本。
- process4cj的posix_spawn和fork/supervisor分支统一显式fd_mappings，exec前关闭除获准stdio/协议编号外所有FD，不仅关闭自己创建的pipe；close-range/closefrom必须避开已批准映射，不能先dup后把它们一起关闭。目标仅继承其声明stdio，helper启动env固定且无loader注入，批准target env只在限制安装后生效。LSP/DAP/MCP framing不混入banner。helper监督一次性目标：主进程退出即停止bridge并退出、销毁bwrap PID namespace全部后代，等待收尾后才返回ToolResult，不能以stdout EOF/完成marker替代。HostNetwork用同一监督但不启动proxy或增加网络限制。
- HTTP proxy 支持 forward 与 CONNECT；SOCKS 仅 CONNECT，远端 DNS，不支持 BIND/UDP ASSOCIATE。验证 absolute authority/Host 一致性、header/framing 歧义和每次目的地；获准的一条请求/隧道不是其他 host 的授权。所有自建协议有版本、长度、deadline 与 owner 校验。
- DNS 仅网关解析。每次连接校验全部候选地址，任何未批准非公网地址导致本次失败；连接已检查数字 sockaddr，不能二次按域名解析。最多 8 个 resolver worker、32 个排队请求，取消/过期迟到答案不得连接，阻塞未归还 worker 继续计入上限。
- Native relay 支持双向 bounded copy、half-close、deadline、幂等 close。header ≤16 KiB，每 lease ≤64 并发连接，每向缓冲 64 KiB；DNS/connect 各 10s、代理握手 5s。已建立 tunnel 受所属 operation/service 生命周期管理，不把短 handshake timeout 当整个工具 timeout，不累计完整响应。
- gateway/bridge 丢失、限制安装失败、owner 取消/退出时关闭连接/lease 并终止对应目标；不留下权限不明的长期进程，不取消其他 owner。SSH 客户端可显式使用 helper 的 SOCKS stdio-connect/ProxyCommand，不改 Git/SSH 全局配置；不支持代理的 TCP/UDP/QUIC 客户端在 Proxy 中失败，不自动授予 HostNetwork。
- 域名规则仅约束所申请的连接authority及经检查的地址，不做TLS中间人解密、业务DLP或获批服务器可信证明，不能阻止获批服务器代转发或同IP虚拟主机的应用层混用；HTTP CONNECT/SOCKS规则不宣称更强隔离。

### 4. 合并沙箱构造、CA 与长期进程管理

目标：新增 `agent_product/src/process_sandbox.cj`；修改 `local_infrastructure.cj`、`direct_process_sandbox.cj`、`process_supervisor.cj`、`process_broker.cj`、`task_product.cj`、`lsp_runtime.cj`、`dap_runtime.cj`、`debug_tool.cj`、`mcp_runtime.cj`、`product.cj`、`config.cj`。

- `ProductSandboxFactory` 成为三处生产 WorkspaceSandboxPolicy 的唯一 composition 入口，持有 toolchain mounts/PATH/资源和 TrustRoots，返回 launch plan、redactor 与带生命周期的句柄；复用 WorkspaceSandboxPolicy，不复制整套配置对象。
- 工厂只从批准的 normalized plan/服务配置获得 NetworkPolicy，不能接受“raw bool true”旁路。文件 RO/RW、readable mount、环境 allowlist 与 secret allowlist仍独立，HostNetwork 不增加 HOME/.ssh/keyring、完整 env、SSH_AUTH_SOCK 或 token。显式 secret policy 和 redaction 在所有模式一致。
- 保留Bash `env`中用户提供字符串的语义，但不将其解释为读取同名宿主secret的许可；当前Bash export并非secretEnvironmentAllowlist。新的proxy/CA保留字段必须在resolver校验，不能仅设置启动env后又允许prepareShellCommand的export覆盖。专用工具自己的host-source映射、secret env/redaction不改为这种字面值路径。
- TrustRoots优先受信`sandbox.ca_bundle`，否则依次选择`/etc/ssl/certs/ca-certificates.crt`、`/etc/ssl/cert.pem`、`/etc/ca-certificates/extracted/tls-ca-bundle.pem`、`/etc/pki/tls/certs/ca-bundle.crt`中存在、可读、非空且可解析的PEM bundle。语义是选定集合，不是向宿主系统roots追加。composition冻结字节及authored/canonical路径身份，在私有runtime中快照，只读挂载，不绑定整个/etc；命令使用快照的SSL_CERT_FILE/CURL_CA_BUNDLE，内置HTTPS read使用同一集合。bundle变化需要新runtime/generation，不在已批准执行中重读可变文件。
- 显式 bundle 无效或需出站网络却无系统 bundle时 `sandbox.ca_unavailable`，不能 TrustAll/-k fallback。纯离线及仅本地 readiness/publish 不依赖 CA。TLS roots 由受信配置选择；结构化tool env覆盖产品选定SSL_CERT_FILE/CURL_CA_BUNDLE时报前置错误。任意Shell程序仍能在自身逻辑中禁用TLS验证，不能声称能阻止用户命令主动使用-k；内置HTTPS client必须验证。
- DirectProcessHandle、LSP/DAP/MCP transport和daemon state持有所属资源，close/取消/启动失败统一幂等释放。eval仍只读写workspace且Denied。只对离线持久shell/kernel复用既有sandboxPlanProfile；按稳定配置做增量长度编码hash，避免拼接完整大字符串再复制成字节；命中后比较完整配置，不把随机endpoint路径作为identity，不凭hash相等证明授权。
- 可用性成功探测按稳定 backend/helper/基础配置在进程内缓存，身份改变失效；失败不伪装永久可用，真实 launch 仍 fail-closed。不要缓存审批或 lease。
- LSP resolve 使用实际 client spec 快照，不用新配置审批后继续旧 client。reload 先关闭旧 client/lease，再授权新配置。workspace MCP/LSP 文件仅提出请求；模型可写文件不能直接授予能力。DAP runInTerminal 的 debuggee 规则不大于已批准 adapter/目标。
- Denied/Mediated 的 ready.port 从 bridge 私有控制通道探测沙箱 loopback；不要求 egress/publish。移除任意 ready.host 外联探测。HostNetwork 在自身 host namespace 探测 loopback，但成功只能证明该端口有服务，不能证明服务属于目标 PID；UI/测试不作更强声明。log+port 必须同时满足。
- publish 用独立 control/data 通道，只在批准后监听宿主 loopback，实际 readiness 检查目标服务而非 forwarder 的监听。HostNetwork 没有 publish 转发，服务自己监听宿主端口，必须在审批明确这项后果。
- broker 保存完整规范 spec、generation、owner 和 canonical 授权引用；收到启动/重启从 canonical store 校验原记录、批准状态、完整 plan、owner/generation，执行内容来自该记录，不信 caller raw args 或自报 digest。manual restart 是新操作；automatic restart 仅原 spec 中已批准的相同规则和生命周期，每代新资源。
- 外部 broker 属受信控制进程，并非模型沙箱。broker 崩溃/takeover 后非终态记录进入 recovery_required，不自动用旧 PID/socket/lease 当健康服务；不能杀死无法验证身份的历史 PID。

### 5. 在 read 路由上增加独立授权 HTTPS 文本读取

目标：`agent_product/src/internal_uris.cj`、`tools.cj`、`product.cj`，新增`https_uri.cj`、`authorized_http.cj`、`authorized_http_native.cj`及`agent_product/native/authorized_http_native.c/.h`；`agent_rpc/src/host_uris.cj`与Product native构建声明。

- 保留唯一 `read` 工具，不新增 http_read/curl_read。内置 https handler 不可由 RPC 覆盖/注销；当前默认没有 HTTP(S) handler，本项是新实现，不把现状描述为已能读取网页。
- URI handler 的 resolve 声明规范 URL、required capabilities、effect/retry、审批、可写性和实现身份。RPC handler 提交声明后仍与 Host ceiling 相交，不能隐式 WorkspaceRead。https write 前置拒绝。
- `read.path` 为绝对 HTTPS URL；可选 `network` 仅允许 proxy 与 egress，用于附加 redirect host/private 地址，禁止 HostNetwork/publish。初始 URL host/port自动生成申请规则，不自动批准。Shell 为 restricted/denied 时专用 read 仍能经自身批准联网；Shell trusted-host 不能绕过其规则。
- URL复用已核实的`stdx.encoding.url.URL.parse`和`current.resolveURL(ref)`，拒绝userinfo、非HTTPS和非法authority；query可能含敏感信息，错误/展示经redactor，不承诺自动识别任意签名token。[URL API](https://955work.icu/dev/stdx/libs_stdx/encoding/url/url_package_api/url_package_classes.html)。
- 明确替换旧计划的read内部`ClientBuilder.connector`方案：该API虽支持Unix stream隧道/TLS和InputStream读取，但`maxHeaderListSize`只限定HTTP/2，`CustomCA`还追加系统roots，无法兑现本计划的HTTP/1解析前硬上限与选定CA集合。不采用事后检查或静默追加信任的降级。[HTTP API](https://955work.icu/dev/stdx/libs_stdx/net/http/http_package_api/http_package_classes.html)、[TLS verify mode](https://955work.icu/dev/stdx/libs_stdx/net/tls/common/tls_common_package_api/tls_common_package_enums.html)。
- `AuthorizedHttpClient`仍是Product内部窄GET接口；新增native TLS stream而非通用HTTP库、模型工具或sandbox helper功能。native层消费已经授权并连接的tunnel handle，提供`openTls/read/write/close`及单调deadline/cancel，不接受可自行解析/连接的新URL。使用OpenSSL 3的独立SSL_CTX，只加载选定CAfile、不调用default verify paths；启用peer链校验，DNS用SSL_set1_host及SNI，IP用X509_VERIFY_PARAM_set1_ip_asc校验IP SAN，禁止TrustAll与验证失败重试。TLS实现留在Product native库，helper继续glibc-only。相关签名/语义已由本机OpenSSL 3.6.4 man3文档核实，组合仍待真实fixture验证。
- Cangjie有界HTTP/1.1 reader在该TLS stream上只发送GET、规范Host、Accept-Encoding: identity及Connection: close；不协商h2、不加载代理/cookie/auth/client-cert/.netrc，不复用ProviderTransport。状态行+headers在超过16 KiB的第一个字节即拒绝，不先构造完整header String。支持Content-Length、chunked和close-delimited body；拒绝TE+CL、重复长度、obs-fold、非法chunk长度及未支持transfer encoding；chunk行/trailers同样有16 KiB上限，最多5个1xx并拒绝101。decoded body逐块计数到8 MiB，数字解析检查溢出，每跳关闭连接，不缓存或自动重试。
- 最多 5 次手动 redirect；每跳重新解析、要求 HTTPS、检查批准规则、重新校验地址。未获准跨域返回 `network.redirect_denied`，附待申请 host，不请求下一跳。GET 按 ExternalMutation/Never/NeverReplay 处理；已有成功 receipt可重放结果，不重发请求。
- 接受text/*、JSON/+json、XML文本MIME；HTML为原始UTF-8，不执行JS、不提供浏览器/reader-mode。DNS/connect各10s由gateway/native实现，不假设stdx存在connectTimeout；包括全部redirect、TLS和读取在内共享30s monotonic deadline，8 KiB块读取并在分配/追加前守住8 MiB上限。未知长度同样受限，拒绝非identity压缩；无效UTF-8、媒体不支持、framing错误和超限分别结构化报错。
- 复用现有 read 行范围、preview/artifact 与 destination。指定 destination 必须在任何 I/O 前同时授权 WorkspaceWrite 与网络，再用 atomic writer；body 先过硬上限再交现有 String/artifact，避免另建无限流式文档仓库。
- 每 operation 拥有 client/response/lease，取消只关该请求。完整观察到的失败/超时/取消有已知终态；崩溃无法确认是否发送/完成时保留 Unknown，不以 GET 名称证明无副作用。

### 6. 迁移其余联网消费者，保持专用工具独立

目标：`github_tool.cj`、`web_search_tool.cj`、`vnext_control.cj`、LSP/DAP/MCP、`agent_extensions/src/extensions.cj`、`agent_sdk/src/extension.cj` 及 manifest/config/broker 编解码。

| 消费者 | 新授权/网络路径 | 必须保留的独立边界 |
| --- | --- | --- |
| GitHub gh/git | 从已选 forge、操作、repo remote冻结 host/port，Mediated launcher；未知 remote/下载跳转/SSH 目标显式追加审批 | 既有 GH_TOKEN/GITHUB_TOKEN allowlist/redaction、工作区写能力、工具 audit；不因 Shell trusted-host读宿主 gh/keyring |
| web_search | 配置 provider endpoint形成具体规则，保留现有 curl与 provider解析，Mediated launcher | `-q`、secret处理、timeout/cancel与 provider配置，不要求 Shell 网络开启 |
| isolated extension | manifest 声明完整规则，SDK networkHttp.resource完整传递 | 原能力/effect/身份校验，不把 generic network.access降成 true |
| MCP stdio | 已批准服务配置 + 工厂 + 原 stdio framing | 本地配置身份、secret_env与 owner生命周期 |
| MCP HTTP | 独立受控 connector/规则，endpoint/redirect每跳检查 | MCP认证/会话/原始协议，remote annotations不能授予网络 |
| LSP/DAP | 实际 spec和 attach host/port冻结，debuggee/runInTerminal不扩权 | 文件、调试与环境权限；不继承 Shell默认 |
| Provider | 受信控制面继续走已配置 endpoint/独立凭据 | 不受某条 shell的 NetworkPolicy约束，不暴露成任意 URL工具 |

- 盘点每个 ProcessRequest、direct persistent launch、HTTP client、broker、manifest 网络调用点，一次迁移。没有具体目的地或受信静态 endpoint的专用网络注册/准备失败；不留下只在注册时“允许 NetworkAccess”而执行时无限宿主网络的分支。
- 专用工具仍产生自身审批/audit/token redaction证据。拒绝、取消、重定向扩权与 endpoint policy错误应归属该工具，不归因于 Shell DNS。
- MCP HTTP的initialize/工具发现也必须先经过受信服务配置授权并记录canonical配置引用、owner与audit；不能只在发现出的工具调用时才检查网络。保留既有MCP HTTP协议和独立TLS/认证设置，用已核实的`ClientBuilder.connector((SocketAddress)->StreamingSocket)`把每个规范endpoint绑定到lease；connector不得按回调地址另做未经检查的DNS/连接。URI取消从run-only键迁移到operation/request identity，run取消枚举其资源，不误杀同run并发请求。
- 同步 workspace外已存在的 sandbox_runtime 镜像消费者以通过新库 API，不把镜像引进生产依赖；删除旧 Boolean网络解码/别名。

### 7. 按效果证据处理错误，修复可前置拒绝的写入

目标：`agent_product/src/local_infrastructure.cj`、`tools.cj`，`tool_runtime/src/prepared.cj`，`agent_domain/src/operation_vnext.cj`。

- 删除仅按 AgentErrorKind决定 `recoverableExecutorError` 的全局规则。已知失败 ToolResult 必须基于完整观察结果或明确未执行证据；handed-off后不明副作用不得因 Timeout/Transport而伪装成安全失败。
- Write resolver前置校验立即父目录存在且为目录、目标类型、权限/敏感路径。缺父目录不隐式 mkdir，不特判示例路径。未执行错误进入模型可修正结果；不把这当成此前未知失败的既定根因。
- writeFile明确 staging、publish、结果确认三阶段；可证明未发布的 staging失败为已知失败；publish后或是否发布未知则交 canonical resolver产生Unknown。保留现有原子替换算法，不声称 rename失败一定无副作用。
- 保留底层 code、phase、必要路径、cause并redact。统一结构化 `error:{code,kind,message,fields}`，外层附operation/outcome/reconciliation；known failure、canonical error与各前端复用一个编码器。JSON-RPC保持协议外壳，同一结构放data。
- 非零退出且输出/终止已完整捕获是已知完成，可以已经产生业务修改；是否成功、效果类别、能否重试分别表达。取消后已证明安全的请求可继续同 session；效果未知的任意命令保留RecoveryRequired，不能为了PTY演示把Unknown降级。

### 8. 让 canonical终态与恢复门禁成为权威

目标：`agent_core/src/core.cj`，`agent_runtime/src/operation_port.cj`、`thread_runtime.cj`、`thread_coordinator.cj`、`recovery.cj`，`agent_store/src/operation_runtime_store.cj`、`thread_registry.cj`、`thread_commit_sink.cj`、`runtime_recovery.cj`、`schema.cj`、`database.cj`及持久Run仓库。

- `RuntimeOperationResolution`已经存在，包含`resolution: OperationResolution`与semanticCommit。将`commitCanonicalToolAttempt`从`Result<Unit>`改为`Result<RuntimeOperationResolution>`；验证semanticCommit后返回整个值。三个调用点及batch/resume/program/result replay读取`resolved.resolution`，Terminal的canonical error优先于raw executor错误，RecoveryRequired也优先于同批先收集的普通fatal。已join的整批结果全部各提交一次，再结算Run，不能遇到第一个Unknown就丢失兄弟结果。
- 语义提交成功但projection失败时从同一canonical结果补投影，不重执行文件/网络、不追加第二份ToolResult。现有Completed Run work-debt检查保留并接入显式managed handoff；不能误称现状完全没有完成门禁，但它不能代替后续Turn的持久检查。
- 共用canonical debt谓词：Unknown receipt且无reconciliation、孤立的mutating handoff/receipt缺口，以及需恢复的未完成事实；正常有效owner持有的已批准后台job/service不是Unknown。`SqliteThreadCommitSink.commitTurnStart`在现有写事务中、任何Turn/Run/Item插入前检查；`SqliteThreadRuntimeRegistry.discardInactive`在active-owner检查与DELETE的同一事务检查。registry冷热获取只做预检，不能代替事务门禁。releaseInactive可释放不再执行的内存缓存但不清除持久debt或据此解除门禁。
- `OperationRecoveryPlanner.inspect(threadId)`扫描所有相关Turn，不因无activeTurnId或已有ToolResult返回空；先检查Unknown receipt是否已对账，再决定FinalizeFromReceipt等安全动作。handoff后无receipt同样显示证据缺口。只在无handoff或有明确safe/idempotent replay依据时重试，Unknown永不重放；补投影、完成拒绝、稳定审批等待继续走现有recovery actions。
- 新`UnresolvedOperation`包含threadId/runId/operationId/toolCallItemId/revision/完整plan、可空receipt及RecoveryActionKind；不能把receipt设为必填而漏掉崩溃后没有receipt的情形。OperationRuntimePort增加`unresolvedOperations(threadId: ThreadId): Result<Array<UnresolvedOperation>>`与`reconcileOperation(threadId: ThreadId, reconciliation: OperationReconciliation): Result<Unit>`。
- `OperationReconciliation`记录reconciliationId、operationId、expectedRevision、bindingDigest、resolution(`applied|not_applied`)、结构化evidence及Host填入的source/observedAtMillis。evidence至少有非空summary。resolution是人工效果事实，不能把applied强行改写成OperationOutcome.Completed，或把not_applied变成自动重试；原Unknown receipt/ToolResult/历史Run不改写。模型不能指定受信source；前端只提交请求字段，Host在真实控制入口构造记录。
- 新`operation_reconciliations`表：id主键、operation_id唯一外键、prior_revision、binding_digest、resolution、evidence、source、observed_at_millis。唯一writer用BEGIN IMMEDIATE：先查同ID已有事实，再校验operation→run→thread归属、未解决状态、expectedRevision和canonical完整plan/状态一致性。bindingDigest仅关联，不代替真实用户身份、唯一operation、revision与不可变plan授权。追加事实、CAS operation为reconciled并revision+1、同步state register和audit，全部原子提交；不设第二个可独立漂移的reconciled布尔值。
- handoff后无receipt的对账也必须可完成：在同一受控恢复事务中，复用canonical receipt/ToolResult编码与唯一约束补一份Unknown终态，再追加人工事实；不伪造已执行成功，不通过要求active Turn的普通执行入口重放。仍有未结束的执行owner时先停止/完成该执行，不让人工对账与活跃executor竞写。其他缺口使用对应安全recovery action，不接受对未执行/正常成功操作随意写reconciliation。
- 幂等检查在当前revision CAS之前：相同ID与完全相同请求字段/source重提交返回已有成功，不生成新时间或新audit；改变resolution/evidence/binding、换ID覆盖同一operation、跨thread或其他stale revision均Conflict。未解决谓词由receipt/事实/owner关系导出，并校验state register一致。SQLite写事务串行化对账与start/delete：先对账完成者可放行，否则前置拒绝。升级内存terminal sink真实记录同类debt，不能继续用今天的no-op sink。
- 对账只关闭证据缺口，不自动重发原命令或恢复旧model continuation。所有未解决事实消除后仅允许新Turn；历史RecoveryRequired Run仍保留历史状态。无法判断时保留门禁，健康新session继续可用。

### 9. 统一产品状态、审批与对账入口

目标：`agent_product/src/application.cj`，`agent_cli/src/commands.cj`、`registry.cj`，`agent_app_protocol/src/protocol.cj`，`agent_rpc/src/product_rpc.cj`，`agent_app/src/main.cj`，`agent_tui/src/tui.cj`及审批数据模型。

- ApplicationSession用统一outcome处理函数覆盖start、resumeStartup、manual/AI decide、handoff、plan correction、goal continuation。从canonical状态更新pendingRecovery/pendingApproval/currentRequest，删除各分支不一致的try-find降级。
- 切换/重开session读durable recovery状态；pendingRecovery只作UI缓存。被阻塞session的队列不执行也不静默丢失。健康session不受其他session污染。
- 新增 `/recovery` 与 `/reconcile <operation-id> applied|not_applied <evidence>`；前者展示原plan、phase/cause、证据缺口，后者先显示binding/revision与后果再真实用户确认。RPC提供同等类型化user command；模型不能提交“已经用户确认”。
- ProductRuntime增加`unresolvedOperations(sessionId)`和`reconcileOperation(sessionId, request)`；先验证session→thread归属，直接查询canonical store，使被执行门禁挡住的session仍可进入只读recovery界面。ApplicationSession提供同名user-control处理；AppCommandPayload新增类型化ReconcileOperation请求，不借用DecideApproval或无证据的ResumeRecovery。CLI/TUI/RPC复用此入口和确认流程，Host决定source/time/权限来源。
- TUI错误卡显示原code/phase、Unknown、operationId及`/recovery`、`/new`。网络审批显示完整effective policy和生命周期；HostNetwork及联网Bash仅显示once/reject。状态区分Shell默认与实际服务策略，不将trusted-host写成全局“无沙箱”。
- CLI/JSONL/RPC/TUI/dump消费同一错误与权限事实；不从缺失证据猜底层cause，不把较少展示字段当较少权限。

### 10. Native包装、存储版本与干净切换

目标：`libs/sandbox4cj/cjpm.toml`、Product native声明，`scripts/prepare_native_deps.sh`、`pinned_cangjie`、`package_candidate.sh`、`package_readiness.py`、`package_readiness_gate.sh`，`packaging/public-packages.toml`与根构建/gate清单。

- LLVM15构建glibc-only helper/socket relay；另外构建Product专用`libaxyndra_http_native`并链接OpenSSL 3，不把TLS依赖带入sandbox helper。pinned wrapper准备相应native roots；candidate显式安装`libexec/sandbox-net-bridge`，将helper及HTTP native库纳入ldd依赖闭包，RPATH按安装布局设置为`$ORIGIN/../lib`，包含所需OpenSSL库/许可证与provenance，不能依赖宿主LD_LIBRARY_PATH或隐式系统包。
- public sandbox4cj源码包staging包含native源/头/helper规则，确定性`llvm-ar rcsD`静态库与helper都进入manifest/provenance，readiness实际编译并运行消费者。Product candidate独立验证HTTP native与TLS依赖；不把它们变成sandbox4cj的公共依赖。移除package_readiness_gate陈旧SDK日期fallback，统一用项目SDK selector和显式AXYNDRA_SDK_ROOT，不降低SDK版本要求。
- 工厂从受信安装路径定位/验证helper；三种模式缺少必需helper、限制安装失败或namespace不支持均fail-closed。HostNetwork仅不建network namespace，仍必须有文件/进程sandbox和监督收尾，绝不fallback完整Host。candidate搬到另一目录、清空LD_LIBRARY_PATH后仍能启动app/helper及sandbox命令。
- canonical数据库以已调查的v21为基线升到新v22，fresh schema包含reconciliation与managed ownership事实、不创建legacy intent表；打开v21/未知版本直接unsupported version，不自动迁移或删表。用户配置使用上述schema_version=1；daemon record、session grant、normalized plan各提升其明确codec版本并拒绝旧格式。无双读/双写、旧Boolean解码、静默忽略/删除旧DB或杀旧PID。验证使用全新settings/state目录，用户旧目录原样保留供人工处理。
- 不保留Boolean网络、旧ToolExecutor overload、intent双账本或raw broker launch fallback。支持的生产、SDK、extension、testkit、RPC、镜像与packaging调用点一次切换；不把编译通过的未接入代码当完成。

**实现依赖：**先完成§1的类型/配置和§2的单一resolver/prepared/canonical契约；在这些接口固定后，§3网关/native与§7–8错误/恢复可以独立推进。§4工厂/服务和§5–6消费者分别接入，§9呈现消费同一事实；最后§10包装与统一门禁。每个切片必须完成真实调用方迁移，不允许只新增尚未被使用的类型/helper。

## Verification

规划阶段仅进行只读源码、API/系统手册查询及`/usr/bin/bwrap --help`检查；未构建、运行测试/fixture、启动服务或修改仓库配置。本机OpenSSL手册为3.6.4，Cangjie以daily SDK为目标；新native/tunnel组合尚无运行证明。以下是实现后的验收要求，不是通过记录。

### 执行顺序与命令

SDK固定 `$HOME/cangjie_sdk/daily`；设 `AXYNDRA_SDK_ROOT` 与 `DISABLE_ZOXIDE=1`，保持 `AXYNDRA_CANONICAL_TARGET_ROOT` 未设置以使用以下产物路径。使用仓库 `scripts/pinned_cangjie`，它准备native依赖并校验SDK；不降低版本要求或安装替代SDK。

1. 先在现有contract加入能暴露能力越界、grant泄漏、Unknown门禁/重复副作用的最小真实回归，再实现对应切片。普通新功能用真实smoke，永久测试只保留不确定的权限/生命周期/协议边界。
2. 从 `support_tests/<contract>` 运行：

```sh
AXYNDRA_SDK_ROOT=$HOME/cangjie_sdk/daily DISABLE_ZOXIDE=1 ../../scripts/pinned_cangjie cjpm build
AXYNDRA_SDK_ROOT=$HOME/cangjie_sdk/daily DISABLE_ZOXIDE=1 ../../scripts/pinned_cangjie target/release/bin/main
```

依次使用`operation_domain_vnext_contract`、`tool_runtime_contract`、`agent_core_contract`、`agent_store_contract`、`thread_runtime_integration_contract`、`sandbox_contract`、`direct_runtime_sandbox_contract`、`product_thread_runtime_contract`、`product_contract`、`sdk_contract`及迁移后的extension/MCP/URI消费者。新增网关/HTTPS场景放在对应既有contract/fixture中，不以源码文本或argv形状断言替代真实边界证明。

3. 仓库根构建真实入口：`AXYNDRA_SDK_ROOT=$HOME/cangjie_sdk/daily scripts/pinned_cangjie cjpm build -m agent_app -o agent_app`。随后用同一wrapper运行实际binary、broker与PTY，避免错用旧candidate。
4. `support_tests/web_search_contract`构建后运行 `../../scripts/pinned_cangjie python3 local_fixture.py --candidate target/release/bin/main`；根目录运行 `bash support_tests/native_provider_security_contract/check.sh`、`scripts/pinned_cangjie python3 support_tests/process_broker_blackbox/check.py --candidate "$(pwd)/target/release/bin/agent_app"`。
5. 全部切片集成后仅运行一次总门禁：`AXYNDRA_SDK_ROOT=$HOME/cangjie_sdk/daily DISABLE_ZOXIDE=1 AXYNDRA_EVIDENCE_DIR="<new-gate-output-directory>" bash scripts/implementation_gate.sh`。占位符替换为尚不存在的独立绝对输出目录。该入口已包含architecture、package_readiness、契约和candidate检查，不再单独重复跑它们；它不运行需外部密钥的real-provider smoke。保留其candidate-path/package-root-path证据，对该relocated candidate再执行新增三模式PTY/进程场景。

配置/CLI补验使用已有 `support_tests/entry_modes_blackbox/check.py`（环境AXYNDRA_BINARY指向本次candidate），以及 `scripts/pinned_cangjie python3 support_tests/frontend_regressions/check.py cli`；ACP用真实workspace-specific session的执行结果证明override生效，不新增仅检查字段转发的测试。持久grant测试必须覆盖生产SQLite，不只MemoryPermissionRepository。

### 必须实际观察的矩阵

| 边界 | 真实刺激与通过条件 |
| --- | --- |
| 三模式 | 同一workspace HTTP/TCP fixture：restricted缺省无连接；host单次申请拒绝为零、批准后成功；下一离线调用仍零；proxy只到批准host/port；trusted-host可直连宿主但manual仍等待批准；proxy显式host在启动前拒绝 |
| 完整审批 | 先批离线session grant再请求Host/Proxy，必须重新审批；A不覆盖B/新端口/private/publish；少NetworkAccess无法靠Approve获权；Host及联网Bash的ApproveSession明确拒绝，第二条Shell命令重新授权；审批后配置/spec/能力漂移零连接 |
| 配置/入口 | 无文件缺省、三种值、非法/重复配置；旧/缺schema版本和旧DB拒绝且原文件不变；config set失败不改文件；CLI split/equal/--边界与direct shell前缺值退出2；CLI覆盖文件、maintenance/ACP保留override；运行快照直到reopen才改变 |
| 进程树 | 普通/PTY/async联网Bash尝试留下后台连接：同步/PTY最终返回或async终态通知、取消、timeout后连接关闭且后代停止；running回执不冒充终态；并发owner不受影响；后续离线执行不继承cwd/export/网络，offline持久语义保留 |
| 文件/环境/凭据 | 每模式读取不可见宿主秘密、写RO/工作区外路径、继承任意ambient变量均失败；显式准许的secret按原策略注入且输出redacted；trusted-host不暴露HOME/keyring/SSH_AUTH_SOCK或完整env |
| Proxy旁路/IPC | 清空proxy env、NO_PROXY、裸IPv4/IPv6 TCP、UDP、SOCKS IP、workspace Unix socket、继承FD、io_uring、重跑bridge均不能扩权；stream socketpair/SCM_RIGHTS内部IPC及调试子进程仍工作，DGRAM pair重定向与bridge ptrace/proc-memory/pidfd攻击失败；HostNetwork对照不误判为逃逸 |
| DNS/协议 | mixed public/private、重绑定、IPv4-mapped IPv6、authority/Host冲突、歧义framing/超大header、worker/连接上限、迟到DNS、half-close尾部字节均有真实连接计数与终态证明；HTTP响应分块/长度/close-delimited、截断、整数溢出、重复CL、TE+CL和16 KiB首个越界字节有实际流输入 |
| TLS/HTTPS read | 测试CA/leaf，明确信任后curl/read成功且无-k；不可信链、DNS与IP SAN不匹配、无roots失败；显式CA1不接受ambient CA2；完整文本/HTML/JSON、五跳边界、跨域拒绝零请求、降级/压缩/超限/非法UTF-8、TLS/read超时与并发取消隔离；destination先审批 |
| 专用工具独立 | 三种Shell模式分别调用web_search/GitHub/HTTPS read/MCP：自己的规则和token策略不变；Shell禁网不阻断已批专用请求，trusted-host不能解锁未批host；Provider原协议/凭据不变 |
| 服务 | Denied/Mediated内部loopback ready不需egress；未publish宿主不可达，批准后可达；forwarder监听不代表目标ready；log+port同时成立；restart/auto restart只有原spec规则；broker崩溃保留recovery门禁 |
| 已知失败 | 缺父目录/非法目标在handoff前拒绝且文件未变，模型收到可修正错误；非零退出是已知完成但不代表无修改 |
| Unknown/对账 | 真写入后注入结果持久化失败：只写一次；Operation/API/Run一致RecoveryRequired；同批兄弟结果也各提交一次；热/冷/reopen的新Turn和delete被挡且无Provider新请求；有Unknown receipt与handoff无receipt两种缺口均可对账；幂等/冲突/跨thread与对账-start/delete竞争；内存SDK同样守门；全债消除后只开新Turn |
| async handoff | running回执后job仍按本次已批规则执行，父Turn可结束；同步/PTY最终返回及async终态通知后树和连接已关闭；晚到完成校验原job owner/generation，不借新Turn扩权；崩溃丢失owner/终态进入recovery而非伪造成功；新离线调用不继承其网络或环境 |
| 包装 | relocated candidate清env能启动真实helper并执行三模式；缺helper/CA/kernel支持明确失败，无Host fallback；public package/SDK消费者编译新接口 |

固定Linux x86_64 gate必须真实运行bwrap，unsupported不能计为pass；其他平台只声明fail-closed边界，不据本机结果声称平台验证。host网络授权包含私网访问，Proxy的保守地址策略可能拒绝fake-IP DNS；报告 `network.address_denied`，不自动改变系统DNS或放宽到Host。

### 真实PTY验收

扩展现有 `support_tests/tui_path_coverage/check.py`、`fixture_server.py`、`scenarios.json`，使用实际agent_app入口、隔离settings/state、确定性本地SSE Provider与实际工具/MCP，不使用内部parser或假TUI。

- 新 `T029/network-policy` 覆盖三模式、批准/拒绝、真实Bash/Hub连接、后台收尾、readiness/publish/restart。
- 新 `T028/https-read` 覆盖实际HTTPS工具、批准/拒绝/取消、后续请求。
- 新 `T027/operation-reconciliation` 覆盖真实写入后持久化故障、Unknown可见、同session门禁、`/new`、reopen、`/recovery`与人工对账。
- 回归 `T007/esc-cancel-recovery`、`T019/provider-errors`、T020 recovery variants、`T023/mcp-http`、`T026/copy-and-suspend`、`T027/restart-cycle`、`T028/builtin-boundaries`、`T029/task-process-boundaries`；T007显式调用normal_exit。T021/tool-loop-cancel区分可证明安全取消和Unknown，不无条件要求后者继续同session。
- Provider至少三个延迟chunk，变化LF/CRLF、JSON和UTF-8边界；观察文本、reasoning、tool、usage、error、terminal、cancel、timeout、EOF不完整事件、非法UTF-8的可见反馈。对取消/超时既证明资源关闭，也证明安全后续请求成功；不压掉真实recovery_required。
- 记录真实Enter/Escape/Ctrl-C/`/exit`及审批/对账键序列、fixture input/请求计数、ANSI/terminal snapshots、exit status。鼠标/resize/终端能力仅在实际runner执行后计入，不以矩阵声明代替证据。

根目录执行新用例（占位符替换为尚不存在的独立绝对输出目录）：

```sh
AXYNDRA_SDK_ROOT=$HOME/cangjie_sdk/daily scripts/pinned_cangjie python3 support_tests/tui_path_coverage/check.py --candidate "$(pwd)/target/release/bin/agent_app" --output "<new-pty-output-directory>" --case T029/network-policy --case T028/https-read --case T027/operation-reconciliation
```

完成标准：十个实施部分全部接入真实入口、旧路径已切断、上述权限/生命周期/恢复/发行证据完整。计划中的新类型、schema和runner variants是待实现契约，不是现有功能或已通过测试。
