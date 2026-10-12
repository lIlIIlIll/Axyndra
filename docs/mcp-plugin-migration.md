# MCP host migration acceptance matrix

Status: implementation and acceptance remain separate. The current source has
removed `agent_mcp`, `extensions/mcp_extension`, Product's embedded MCP runtime
and App's dedicated `mcp_server_cli`. App, Product and Extensions no longer
import `mcp4cj`; protocol algorithms belong to the independent Client/Server
packages and the optional library contracts. Shared Host lifecycle owners do
not import either MCP package or library. This is a source fact, not proof that
the complete installed MCP surface works in the current Minimal executable.

The current protocol inventory is **51 Client and 20 Server cases**. The Client
official helper requires all 51 cases without skips; the Server checker requires
all 20. Each uses real packaged executables and real peers, but its host broker
is a protocol fixture. These checks prove protocol and package behavior; they
do not create or verify canonical host permission, Run, Operation or Receipt
authority. Build fresh packages when any transitive source, lock or SDK input
differs; a previously passing package is not evidence for changed source.

Earlier installation evidence passed two Client transports and nine Server
ingress scenarios on one fixed, physically MCP-free **full App** executable.
That executable retained other business packages. Those records remain valid
only for their recorded graph; they do not prove current Minimal assembly or
complete parity with the removed implementation. Current Minimal acceptance
must install both independent packages into the same actual host binary and
exercise its real shared lifecycle and External ingress owners.

The table retains the pre-removal source anchors and old supported behavior.
Its remaining tests are requirements, not declarations that unsupported-only
diagnostics or source deletion complete A2. An explicit new unsupported
diagnostic does not preserve an old supported feature.

| Old surface / evidence | Actual old boundary | Replacement and remaining acceptance |
| --- | --- | --- |
| `mcp_runtime.cj:949` `parseProductMcpConfig` | `mcp.yml` version 1, explicit servers block and per-server id/enabled/transport; rejects duplicates, unknown fields, bad indentation and transport-mixed fields | Generic operator JSON grants plus plugin-owned nonsecret config. Preserve old bytes, inspect as historical data; no automatic interpretation or launch. A tested migration command/document must map supported fields to explicit grants. |
| `loadProductMcpConfig`, `startProductMcp` | Missing file means zero servers. Enabled false skips launch and secret resolution. Enabled true eagerly discovers during Product startup; startup failures have typed lifecycle handling | Minimal startup never discovers. Explicit persistent `/plugins service start ... --approve` is the intentional approval migration; absent grant/approval must make zero I/O. Independent service list/stop replaces host-specific `/mcp`. |
| `pluginMcpServerConfig`, old Product plugin tests | Codex inline/path/companion declarations supported; package cannot bind operator credentials or private HTTP endpoints. User/workspace effective package scope and quarantine/rollback existed | Native installed component plus exact namespace/digest grant. Historical files remain blocked data. Import/disable/update/rollback must revoke actual leases/catalog and preserve artifacts. No silent old endpoint restart. Native lifecycle/manager tests cover portions; complete package-update matrix still required. |
| `finalizeProductMcpServer:1180`, `runStdioCompositionContract` | Stdio executable, argv, cwd; arguments remain argv, not shell; sandbox workspace read-only, package/cwd/toolchain/CA mounts normalized | Generic lifecycle binds canonical executable/hash, argv, explicit mounts and cwd. Need actual equivalent non-root cwd/relative executable/interpreter/package dependency fixtures; hardcoded workspace cwd alone is not full parity. |
| `resolveProductMcpEnvironment:1618`, `runStdioNetworkModeContract` | Ordinary `env` maps target variable to explicit host source; missing source is error; ambient environment withheld | Shared lifecycle now binds operator-owned immutable nonsecret values/source resolution in the launch plan and revalidates them at launch. Ambient variables remain withheld. Actual equivalent MCP environment/missing-source fixtures remain required in the current host graph. |
| Same plus `productMcpSecretValues`, extension recursive redactor | Explicit `secret_env` was supported. Secret-like names must use it. Child sees secret; tool text/structured values/errors/discovery schemas are redacted; no ambient API keys | Shared lifecycle now retains opaque process credential references, resolves concrete secrets only after the actual handoff, and filters raw/escaped stdout/stderr before plugin IPC. Secret resolvers and concrete launch bindings remain internal. Current-host MCP reflection (including discovery/errors), absence from plan/Receipt/logs, cancel and configuration revocation tests remain required. |
| `productMcpNetworkPolicy:1149`, `openSandboxedProductMcpStdio`, actual `runStdioNetworkModeContract(host)` | Default Denied, explicit `network: host` admitted and actually exercised with network success. `network: proxy` is rejected because old YAML cannot express egress. Boolean values rejected | Shared lifecycle accepts the explicit generic network policy and binds it to the actual canonical launch; it does not reject host mode merely because the service speaks MCP. Verify accepted/denied HostNetwork with real MCP peers in the current graph. Mediated-only substitution would change reachable behavior. Old proxy mode need not be invented as supported. |
| `SSL_CERT_FILE` / `CURL_CA_BUNDLE` resolution and sandbox CA mount | Explicit TLS trust environment and CA path reached process/network boundary | Need generic fixed trust-file mount/env binding and live HTTPS/CA fixture. HTTP curl trust policy is distinct from stdio child trust. |
| `finalizeProductMcpServer:1211`, library config validation | `streamable-http`, exact URL including query, HTTPS except loopback HTTP; no host-prefix confusion; optional prefer_sse | HTTP plugin config + frozen full request + real Product local origin tests staged. HTTPS trust and raw query must use actual gateway/curl. `prefer_sse` is an actual Accept wire projection, not cosmetic. |
| `agent_mcp/http.cj:42` | `bearer_token_env` resolved before opening, automatic `Bearer ` prefix, header injection/newline checks, missing source error; secret never embedded in config DTO | Shared HTTP credential bindings retain operator-only prefix and bare/prefixed redaction. A real origin must receive `Bearer <secret>` while plugin/Receipt/history do not. Earlier full-App proof does not replace current-host secret-reflection acceptance. |
| `headers` YAML map and HTTP facade | Arbitrary valid custom header maps to operator env source. Reserved protocol/auth/Origin headers rejected. Values resolved by host and redacted | Existing opaque grant header injection plus strict operator binding preserves secret custom headers; root public-header/Origin candidate covers nonsecret metadata separately. Need origin observation plus secret reflection evidence, including short/encoded secrets. |
| `origin`, `McpStreamableHttpClientConfig` | Explicit secure Origin allowed. `prefer_sse`, bearer, custom headers and protocol headers coexist | Root compatibility candidate forwards validated nonsecret Origin/public headers through library freeze. Header casing/duplicates/security fields must remain strict. |
| `openProductMcpTransport:1360` | Product HTTP obtains gateway lease and installs its authenticated loopback proxy. YAML has no arbitrary proxy field. Library facade separately supports explicit loopback proxy URL | Generic Mediated gateway is the Product replacement. Plugin cannot choose proxy/credentials. Direct optional library contract preserves loopback proxy validation; it does not grant plugin proxy authority. |
| `McpAgentExtension:117` | Remote name is sanitized/hashed into `mcp__...`; collisions detected; schema/description retained and redacted | Independent plugin stable hashed local-name map plus owner-scoped Thread catalog. Alias spelling changes intentionally with namespace; migration must expose old→new identity mapping rather than claim identical names. Schema/content may not silently disappear. |
| `trusted_read_only_tools` parser and extension:145 | Operator exact remote-name list makes a descriptor non-side-effecting and may remove approval; remote annotations alone never do | Shared generic service grants now include an exact operator-owned `read_only_tools` effect ceiling, bound to the published package/service/tool/schema and frozen request. Server annotations do not grant it. Test actual approval/read-only policy in the current host; startup opaque I/O remains conservative. |
| `discoverMcpExtension` → `client.toolDirectory(forceRefresh:true)` | Actual discover plus complete pagination; ttl/cacheScope consistency from library; no Product explicit refresh loop found | Plugin bounded pagination preserves metadata consistency, duplicate/cursor validation, supports empty directory; explicit same-endpoint refresh and catalog CAS are stronger. Capacity limits below still require parity review. #39 actual active-Run cut remains separate verification. |
| `McpToolExecutor.execute:39` | Complete content/structuredContent/isError exposed as ordinary ToolResult | New generic service terminal and exact child Receipt must preserve complete business error separately from transport Unknown. Actual stdio tests passed in earlier graph; HTTP Product tests staged. |
| `McpToolExecutor.execute:48..85` | Product never continued InputRequired; returned `mcp.tool_input_required`. Task returned `mcp.tool_task_pending`; required-task tools were skipped. Extension result types returned unsupported | New typed no-continuation outcomes preserve Product fail-closed semantics. Returning pending structured result for inspection is allowed, but no automatic extra write/retry or fake complete. Library has fuller APIs retained independently. |
| `agent_mcp/client.cj` facade methods | Library-facing SDK facade exposed prompt/resource/completion/task/subscription methods; Product Tool adapter did not mount those contribution types | Independent `mcp4cj` keeps algorithms, but deleting public facade is an SDK API break. A6 migration must identify the new independent package API; cannot call Product tool-only tests evidence of all protocol methods. |
| Tool owner cancellation and stdio shutdown | Real Run-scoped correlation, cancel notification, bounded close; Unknown lost result is not automatically retried | New plugin closes poisoned session rather than sending an unfrozen cancel frame; host aborts exact lease, persists Unknown and requires new canonical launch. Verify actual server process/sockets close, late result rejection, one Receipt, and no retry. |
| Stdio `max_frame_bytes`, `request_timeout_ms`, `graceful_shutdown_ms` | YAML forwards positive configured values into McpFramingConfig. Library defaults 8MiB/30s/3s **do not alone prove Product effective limits** | New pure prepare/frame and directory bounds (~30KiB request; 64KiB prepare/directory; 8 pages/64 tools; ≤10s request; 4096 IDs/session) are visibly tighter local limits. Audit global Tool/Store/Runtime bounds and create boundary fixtures before deciding actual supported delta. See follow-up effective-limit audit; no unsupported-only closure. |
| Old Product server `ProductMcpToolHost` | Capability-filtered catalog; real Direct root per request; typed numeric/text IDs; hidden tools absent; approval refusal; InputRequired retry unsupported | Independent Server + generic raw-sealed External ingress, same catalog and Store, actual credentials/principal grant. Server plugin library parser owns MCP. Must run same fixed Minimal host with installed Client and Server; staged source is not evidence. |
| Server CLI / App / TUI | Dedicated `mcp-server`, `/mcp`, status APIs previously routed embedded runtime | Remove dedicated branches. Generic persistent services/serve contribution commands own lifetime. Unknown old command plus migration docs, not a permanent compatibility dispatcher. `/exit`/`/quit` require actual cleanup ACK. |
| Persisted files/history | Installed content snapshots, old names, Items, Operations and Receipts exist | Preserve bytes and readable history. No migration grants from embedded connection/principal/source payload. Old Prepared executor identities must not silently redirect to new installed component. |

## Remaining acceptance gates

1. All reachable supported rows above have an equivalent generic implementation
   and actual accepted/denied/cancel/unknown regression, or user-approved scope
   change. A new unsupported diagnostic is not an implementation.
2. Rebuild optional `mcp_contract`, which directly consumes `mcp4cj` without
   `agent_mcp` or Product. Keep library conformance tests and their existing
   explicit protocol support boundaries. The standalone package checks are
   a separate gate.
3. A clean source input contains no agent_mcp, mcp_extension, mcp4cj or plugin
   source and builds the real host without old cache. Record exact source graph
   and binary hash. The input builder alone is not build proof.
4. Install independently built Client and Server into that same fixed Minimal
   binary; run actual supported stdio/HTTP/ingress operations, stop/remove and
   reinstall without host rebuild. Verify the executable, package, SDK and
   source hashes across every phase. Exercise the real maintenance HostService
   source and sealed External connection/frame; an ordinary direct Tool call
   cannot stand in for lifecycle admission. Require actual cleanup ACK and
   retain every failed, skipped or unexecuted attempt as such.

## StdX compatibility proxy routing

The compatibility HTTP adapter selects `ClientBuilder.noProxy()` when `proxyUrl` is empty. This deliberately changes the previous SDK-default behavior, which could inherit an ambient HTTP or HTTPS proxy. An explicit nonempty proxy continues through the existing loopback validation and both original SDK proxy setters.

This choice does not grant a host capability or network authorization. Plugins still inject their broker, and its admission, credentials, cancellation and response ownership remain authoritative. The implementation does not change environment variables.
